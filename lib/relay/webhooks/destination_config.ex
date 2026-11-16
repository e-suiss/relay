defmodule Relay.Webhooks.DestinationConfig do
  @moduledoc """
  The configuration one delivery attempt hands its destination (WH-17, WH-19). The stored destination of an endpoint holds no secret: a credential is only ever the identifier of a secret reference, and it is resolved here, through the engine's runtime, for this attempt alone. The resolved secret is a wrapped value from here to the place it is used; it reaches no log, no job argument and no attempt record.

  An HTTPS endpoint gets its address and, when it asks for more than the signature, either its client certificate with the private key the credential holds (`auth: mtls`) or its OAuth 2.0 client with the client secret the credential holds (`auth: oauth2_client_credentials`). Every other kind gets the fields of its stored destination that the destination module knows, and the secret as `:credential`.

  A credential that cannot be resolved now is a failure of class `:credentials`, which is tried again; a client certificate that cannot be read is `:invalid`. Neither made an attempt.
  """

  alias Relay.Redacted
  alias Relay.Scope
  alias Relay.Webhooks.Destination
  alias Relay.Webhooks.Destination.Socket
  alias Relay.Webhooks.Settings

  # WH-17
  # WH-19
  @doc "Builds the configuration of `module` for an endpoint as the engine reads it. Never runs inside a transaction."
  @spec build(Scope.t(), module(), map()) :: {:ok, map()} | {:error, Destination.failure()}
  def build(%Scope{} = scope, module, %{"destination" => destination} = endpoint) do
    case credential(scope, endpoint["credential_ref_id"]) do
      {:ok, credential} -> configured(endpoint, module, destination, credential)
      :error -> unattempted(:credentials, "credential_unavailable")
    end
  end

  defp credential(_scope, nil), do: {:ok, nil}

  defp credential(scope, ref_id) do
    case Settings.runtime().credential(scope, ref_id) do
      %Redacted{} = credential -> {:ok, credential}
      _unresolved -> :error
    end
  end

  defp configured(%{"kind" => "https", "url" => url}, _module, destination, credential) do
    case Map.get(destination, "auth", "none") do
      "none" -> {:ok, %{url: url}}
      "mtls" -> mtls(url, destination, credential)
      "oauth2_client_credentials" -> oauth2(url, destination, credential)
      _other -> unattempted(:invalid, "auth_invalid")
    end
  end

  defp configured(_endpoint, module, destination, credential) do
    _ = Code.ensure_loaded(module)

    config =
      for {key, value} <- destination, atom = field(key), atom != nil, into: %{} do
        {atom, value}
      end

    {:ok, Map.put(config, :credential, credential)}
  end

  defp field(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  # WH-17
  defp mtls(url, %{"client_certificate" => pem}, %Redacted{} = key) when is_binary(pem) do
    case Socket.client_certificate(pem, key) do
      {:ok, %{} = certificate} -> {:ok, %{url: url, client_certificate: certificate}}
      _unreadable -> unattempted(:invalid, "invalid_client_certificate")
    end
  end

  defp mtls(_url, _destination, _credential),
    do: unattempted(:credentials, "credential_unavailable")

  # WH-17
  # WH-43
  defp oauth2(url, %{"token_url" => token_url, "client_id" => id} = destination, credential)
       when is_binary(token_url) and is_binary(id) and is_struct(credential, Redacted) do
    client = %{token_url: token_url, client_id: id, client_secret: credential}

    case destination |> Map.get("scopes", []) |> Enum.join(" ") do
      "" -> {:ok, %{url: url, oauth2: client}}
      scope -> {:ok, %{url: url, oauth2: Map.put(client, :scope, scope)}}
    end
  end

  defp oauth2(_url, _destination, _credential),
    do: unattempted(:credentials, "credential_unavailable")

  defp unattempted(class, reason),
    do: {:error, %{class: class, reason: reason, duration_ms: 0, address: nil}}
end
