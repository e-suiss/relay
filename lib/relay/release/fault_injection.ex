defmodule Relay.Release.FaultInjection do
  @moduledoc """
  The fault injection release commands of the installation operator (OP-92, OP-44): `bin/relay eval 'Relay.Release.FaultInjection.engage(operator: "…", reason: "…", kind: :rate_limited_429, rate: 50, ttl: "30m", environment: :test)'`.

  Every write names the operator (`operator:`) and a reason (`reason:`). A new record needs its kind (`kind:`), its rate in percent (`rate:`, 0–100), its TTL (`ttl:` such as `"90s"`, `"30m"` or `"1h"`, at most one hour) and the environment it targets (`environment:`, `:test`, or `:live` only on an installation running with `RELAY_CHAOS_MODE=true`); `tenant:` (`ten_…`) narrows it to one tenant, `channel:` and `provider:` to one channel and one provider, and `delay_ms:` gives the latency of `added_latency` and the report delay of `delayed_delivery_report`. Every write is audited and signalled to the nodes; running one twice changes nothing more. Results are `{:ok, map}` or `{:error, atom}`.
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.FaultInjection], exports: []

  alias Relay.FaultInjection

  @ttl ~r/\A([1-9][0-9]{0,3})([smh])\z/
  @units %{"s" => 1, "m" => 60, "h" => 3_600}

  # OP-92
  # OP-44
  @doc "Engages a fault injection; see the module documentation for the options."
  @spec engage(keyword()) :: {:ok, map()} | {:error, atom()}
  def engage(opts) when is_list(opts) do
    with {:ok, operator} <- operator(opts),
         {:ok, scope_kind, tenant_id} <- scope(opts[:tenant]),
         {:ok, ttl} <- ttl(opts[:ttl]) do
      spec = %{
        scope_kind: scope_kind,
        tenant_id: tenant_id,
        environment: opts[:environment],
        channel: opts[:channel],
        provider: opts[:provider],
        kind: opts[:kind],
        rate_percent: opts[:rate],
        delay_ms: opts[:delay_ms],
        reason: opts[:reason],
        ttl_seconds: ttl
      }

      FaultInjection.engage(spec, operator)
    end
  end

  # OP-92
  # OP-44
  @doc "Clears a fault injection. Options: `operator:` and `reason:`."
  @spec clear(String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def clear(id, opts) when is_binary(id) and is_list(opts) do
    with {:ok, operator} <- operator(opts),
         do: FaultInjection.clear(id, opts[:reason], operator)
  end

  # OP-92
  @doc "Lists the fault injections in force, or with `include_inactive: true` the cleared and expired ones too."
  @spec list(keyword()) :: {:ok, map()} | {:error, atom()}
  def list(opts \\ []) when is_list(opts) do
    case FaultInjection.list(include_inactive: Keyword.get(opts, :include_inactive, false)) do
      {:ok, records} -> {:ok, %{fault_injections: Enum.map(records, &FaultInjection.describe/1)}}
      {:error, code} -> {:error, code}
    end
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

  defp scope(nil), do: {:ok, :installation, nil}

  defp scope("ten_" <> _ = text) do
    case Relay.ExternalId.decode(text, ["ten"]) do
      {:ok, id} -> {:ok, :tenant, id}
      {:error, _} -> {:error, :invalid_tenant}
    end
  end

  defp scope(_tenant), do: {:error, :invalid_tenant}

  defp ttl(text) when is_binary(text) do
    case Regex.run(@ttl, text) do
      [_, amount, unit] -> {:ok, String.to_integer(amount) * Map.fetch!(@units, unit)}
      nil -> {:error, :invalid_ttl}
    end
  end

  defp ttl(_ttl), do: {:error, :invalid_ttl}
end
