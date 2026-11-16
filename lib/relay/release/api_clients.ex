defmodule Relay.Release.ApiClients do
  @moduledoc """
  The API client release commands of the installation operator (E-99): list the API clients Access registered that wait for their environment and scopes, and assign one. They run on a running node through the release script `bin/api-client` (`bin/api-client pending --tenant ten_…`, `bin/api-client assign --operator … --tenant ten_… --environment live --client app_… --scopes publish,read`), or directly as `bin/relay rpc 'Relay.Release.ApiClients.assign(operator: "…", tenant: "ten_…", environment: :live, client: "app_…", scopes: ["publish"])'`.

  An assignment takes the same audited path as the operator endpoint `POST /v1/operator/pending_api_clients/assign` (`Relay.Access.assign_api_client/4`): `api_client.assigned` and `api_client.created` are recorded with the installation operator named by `operator:` as the actor, and every node sees the client from then on. Results are `{:ok, map}` or `{:error, atom}`.
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Access],
    exports: []

  @scopes ~w(publish read subscribers config kill_switch)
  @switches [operator: :string, tenant: :string, environment: :string, client: :string]

  # E-99
  @doc "Lists the pending API clients of a tenant. Options: `tenant:` (`ten_…`)."
  @spec pending(keyword()) :: {:ok, map()} | {:error, atom()}
  def pending(opts) when is_list(opts) do
    with {:ok, tenant_id} <- tenant(opts[:tenant]),
         {:ok, clients} <- result(Relay.Access.pending_api_clients(tenant_id)) do
      pending =
        for client <- clients,
            do: %{access_client_id: client.access_client_id, created_at: client.created_at}

      {:ok, %{pending: pending}}
    end
  end

  # E-99
  # API-75
  # TN-48
  @doc "Assigns a pending API client. Options: `operator:`, `tenant:` (`ten_…`), `environment:` (`:live` or `:test`), `client:` (the Access `client_id`) and `scopes:` (a list of API-75 scopes)."
  @spec assign(keyword()) :: {:ok, map()} | {:error, atom()}
  def assign(opts) when is_list(opts) do
    with {:ok, actor} <- operator(opts[:operator]),
         {:ok, tenant_id} <- tenant(opts[:tenant]),
         {:ok, environment} <- environment(opts[:environment]),
         {:ok, client} <- client(opts[:client]),
         {:ok, scopes} <- scopes(opts[:scopes]),
         scope = Relay.Scope.new!(tenant_id, environment),
         {:ok, client} <- result(Relay.Access.assign_api_client(scope, client, scopes, actor)) do
      {:ok, %{access_client_id: client, environment: environment, scopes: Enum.sort(scopes)}}
    end
  end

  # E-99
  @doc "Runs the command that `bin/api-client` names in `encoded`: its arguments, one per line, in base64. Prints the result and returns it."
  @spec run(String.t()) :: {:ok, map()} | {:error, atom()}
  def run(encoded) when is_binary(encoded) do
    result =
      case Base.decode64(encoded) do
        {:ok, text} -> text |> String.split("\n", trim: true) |> command()
        :error -> {:error, :invalid_arguments}
      end

    IO.puts(inspect(result, pretty: true))
    result
  end

  defp command(["pending" | args]), do: with_options(args, &pending/1)

  defp command(["assign" | args]) do
    with_options(args, fn opts ->
      scopes = opts |> Keyword.get(:scopes, "") |> String.split(",", trim: true)
      assign(Keyword.put(opts, :scopes, scopes))
    end)
  end

  defp command(_args), do: {:error, :unknown_command}

  defp with_options(args, fun) do
    case OptionParser.parse(args, strict: [{:scopes, :string} | @switches]) do
      {opts, [], []} -> fun.(opts)
      _invalid -> {:error, :invalid_arguments}
    end
  end

  defp operator(operator) when is_binary(operator) and byte_size(operator) in 1..256 do
    case Relay.Actor.new(:installation_operator, String.trim(operator), String.trim(operator)) do
      {:ok, actor} -> {:ok, actor}
      {:error, _error} -> {:error, :operator_required}
    end
  end

  defp operator(_operator), do: {:error, :operator_required}

  defp tenant("ten_" <> _ = text) do
    case Relay.ExternalId.decode(text, ["ten"]) do
      {:ok, id} -> {:ok, id}
      {:error, _error} -> {:error, :invalid_tenant}
    end
  end

  defp tenant(nil), do: {:error, :tenant_required}
  defp tenant(_text), do: {:error, :invalid_tenant}

  defp environment(nil), do: {:error, :environment_required}

  defp environment(environment) do
    case Relay.Environment.cast(environment) do
      {:ok, environment} -> {:ok, environment}
      {:error, _error} -> {:error, :invalid_environment}
    end
  end

  defp client(client) when is_binary(client) and byte_size(client) in 1..256, do: {:ok, client}
  defp client(_client), do: {:error, :client_required}

  defp scopes([_ | _] = scopes) do
    if length(scopes) <= 5 and Enum.all?(scopes, &(&1 in @scopes)),
      do: {:ok, Enum.uniq(scopes)},
      else: {:error, :invalid_scopes}
  end

  defp scopes(_scopes), do: {:error, :invalid_scopes}

  defp result({:ok, value}), do: {:ok, value}
  defp result({:error, %Relay.Error{code: code}}), do: {:error, code}
  defp result({:error, _reason}), do: {:error, :service_unavailable}
end
