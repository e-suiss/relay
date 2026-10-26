defmodule Relay.Release.KillSwitch do
  @moduledoc """
  The kill switch release commands, the only write surface of stage 2 (TN-70 (1), TN-45): `bin/relay eval 'Relay.Release.KillSwitch.engage(operator: "…", reason: "…", ttl: "2h", scope: :platform)'`.

  Every call names the operator (`operator:`, recorded as the installation operator acting on its own behalf) and a reason (`reason:`); a new record needs a TTL (`ttl:` such as `"90s"`, `"30m"`, `"2h"` or `"1d"`) or an explicit no-TTL approval (`no_ttl_approval:`), and stopping `security` messages a security approval (`security_approval:`). Relaxing, that is a release, a replacement that relaxes or a resume, needs `confirm_relax:`, the approval reference. Each call is authorized, written with its audit record and outbox event and signalled to the nodes. Results are `{:ok, map}` or `{:error, atom}`.

  The direct SQL emergency procedure calls the same `relay_fn.kill_switch_*` functions and then publishes the generation on `relay:s:signal:killswitch` (TN-45).
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.Tenancy.KillSwitch], exports: []

  alias Relay.Tenancy.KillSwitch

  @scopes [:platform, :tenant, :subtenant, :campaign, :workflow, :api_client, :sender]
  @ttl ~r/\A([1-9][0-9]{0,6})([smhd])\z/
  @units %{"s" => 1, "m" => 60, "h" => 3_600, "d" => 86_400}

  # TN-70 (1)
  # TN-36
  # TN-41
  # TN-42
  @doc """
  Engages a kill switch. Options: `operator:`, `reason:`, `ttl:` (or `no_ttl_approval:`), `scope:` (#{Enum.map_join(@scopes, ", ", &inspect/1)}), `tenant:` (`ten_…`) and `environment:` (`:live` or `:test`) for every scope but `:platform`, `scope_ref:`, `channel:`, `target:` (a `:provider_account` or `:template` tuple with its identifier), `message_class:`, `security_approval:`, `state:` (`:off`, the default, a `:canary` tuple with a percent from 1 to 99 or a `:paused_until` tuple with a `DateTime`) and `ticket:`.
  """
  @spec engage(keyword()) :: {:ok, map()} | {:error, atom()}
  def engage(opts) when is_list(opts) do
    with {:ok, operator} <- operator(opts),
         {:ok, scope_kind} <- scope_kind(opts),
         {:ok, scope} <- scope(scope_kind, opts),
         {:ok, expires_at} <- ttl(opts) do
      spec = %{
        scope_kind: scope_kind,
        scope: scope,
        scope_ref: opts[:scope_ref],
        channel: opts[:channel],
        target: Keyword.get(opts, :target, :all),
        message_class: opts[:message_class],
        security_approval: opts[:security_approval],
        state: Keyword.get(opts, :state, :off),
        reason: opts[:reason],
        ticket: opts[:ticket],
        expires_at: expires_at,
        no_ttl_approval: opts[:no_ttl_approval]
      }

      KillSwitch.engage(spec, operator)
    end
  end

  # TN-22
  # TN-70 (1)
  @doc "Replaces an active kill switch by one of the same dimensions. Options: `operator:`, `reason:`, `state:`, `ttl:` or `no_ttl_approval:`, and `confirm_relax:` when the replacement relaxes."
  @spec replace(String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def replace(id, opts) when is_list(opts) do
    with {:ok, operator} <- operator(opts),
         {:ok, expires_at} <- ttl(opts) do
      KillSwitch.replace(
        id,
        %{
          reason: opts[:reason],
          state: Keyword.get(opts, :state, :off),
          expires_at: expires_at,
          no_ttl_approval: opts[:no_ttl_approval],
          relax_approval: opts[:confirm_relax]
        },
        operator
      )
    end
  end

  # TN-22
  # TN-40
  # TN-70 (1)
  @doc "Releases an active kill switch. Options: `operator:`, `reason:` and `confirm_relax:` (required). Paused deliveries stay paused."
  @spec release(String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def release(id, opts) when is_list(opts) do
    with {:ok, operator} <- operator(opts),
         do:
           KillSwitch.release(
             id,
             %{reason: opts[:reason], relax_approval: opts[:confirm_relax]},
             operator
           )
  end

  # TN-40
  # TN-70 (2)
  @doc "Resumes the deliveries a kill switch paused through the policy lattice. Options: `operator:`, `reason:` and `confirm_relax:`. In stage 2 the lattice is not ready and the command returns `{:error, :policy_lattice_unavailable}` without changing anything."
  @spec resume(String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def resume(id, opts) when is_list(opts) do
    with {:ok, operator} <- operator(opts) do
      change =
        %{reason: opts[:reason], relax_approval: opts[:confirm_relax]}
        |> put_present(:lattice, opts[:lattice])
        |> put_present(:job, opts[:job])

      KillSwitch.resume(id, change, operator)
    end
  end

  # TN-47
  @doc "Cancels every delivery a kill switch paused, each with `cancelled` and a `rule_id`. Options: `operator:` and `reason:`."
  @spec bulk_cancel(String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def bulk_cancel(id, opts) when is_list(opts) do
    with {:ok, operator} <- operator(opts),
         do: KillSwitch.bulk_cancel(id, %{reason: opts[:reason]}, operator)
  end

  # TN-41
  @doc "Lists kill switches: with `tenant:` and `environment:` that scope's records, platform records included (`include_released:` adds released ones); without them every record in force."
  @spec list(keyword()) :: {:ok, map()} | {:error, atom()}
  def list(opts \\ []) when is_list(opts) do
    result =
      case {opts[:tenant], opts[:environment]} do
        {nil, nil} ->
          KillSwitch.list_active()

        _ ->
          with {:ok, scope} <- tenant_scope(opts),
               do:
                 KillSwitch.list(scope,
                   include_released: Keyword.get(opts, :include_released, false)
                 )
      end

    case result do
      {:ok, records} -> {:ok, %{kill_switches: Enum.map(records, &KillSwitch.describe/1)}}
      {:error, %Relay.Error{code: code}} -> {:error, code}
      {:error, code} -> {:error, code}
    end
  end

  @doc "Shows one kill switch record in force."
  @spec show(String.t()) :: {:ok, map()} | {:error, atom()}
  def show(id) do
    with {:ok, record} <- KillSwitch.show(id), do: {:ok, KillSwitch.describe(record)}
  end

  defp operator(opts) do
    case opts[:operator] do
      operator when is_binary(operator) and byte_size(operator) in 1..256 ->
        if String.trim(operator) == "",
          do: {:error, :operator_required},
          else: {:ok, %{kind: :installation_operator, ref: operator}}

      _ ->
        {:error, :operator_required}
    end
  end

  defp scope_kind(opts) do
    case Keyword.get(opts, :scope) do
      scope when scope in @scopes -> {:ok, scope}
      _ -> {:error, :invalid_scope}
    end
  end

  defp scope(:platform, _opts), do: {:ok, nil}
  defp scope(_kind, opts), do: tenant_scope(opts)

  defp tenant_scope(opts) do
    with {:ok, tenant_id} <- tenant(opts[:tenant]),
         {:ok, environment} <- environment(opts[:environment]),
         do: {:ok, Relay.Scope.new!(tenant_id, environment)}
  end

  defp tenant(nil), do: {:error, :tenant_required}

  defp tenant("ten_" <> _ = text) do
    case Relay.ExternalId.decode(text, ["ten"]) do
      {:ok, id} -> {:ok, id}
      {:error, _} -> {:error, :invalid_tenant}
    end
  end

  defp tenant(_text), do: {:error, :tenant_lookup_unsupported}

  defp environment(nil), do: {:error, :environment_required}

  defp environment(environment) do
    case Relay.Environment.cast(environment) do
      {:ok, environment} -> {:ok, environment}
      {:error, _} -> {:error, :invalid_environment}
    end
  end

  defp ttl(opts) do
    case opts[:ttl] do
      nil ->
        {:ok, nil}

      text when is_binary(text) ->
        case Regex.run(@ttl, text) do
          [_, amount, unit] ->
            seconds = String.to_integer(amount) * Map.fetch!(@units, unit)
            {:ok, DateTime.add(Relay.Clock.utc_now(), seconds, :second)}

          nil ->
            {:error, :invalid_ttl}
        end

      _ ->
        {:error, :invalid_ttl}
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
