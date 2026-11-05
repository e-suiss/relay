defmodule Relay.Channels.Ambiguity do
  @moduledoc """
  What follows an attempt whose outcome is uncertain: the request may have reached the provider but no answer came (T-28, CH-10, INV-9, INV-13). A request that never reached the provider is not uncertain; it is a `transient` failure and is retried.

    * A provider that supports an idempotency key is retried with the same key, which stays stable across the logical send (OP-6 (4)).
    * Otherwise the declared `provider_idempotency_policy` decides: `wait_and_query` asks the provider's status endpoint before anything is sent again, `retry_accepting_duplicate_risk` retries, `no_auto_retry` leaves the attempt `unknown` with no automatic second send.
    * On a paid channel an uncertain attempt is retried at most once and the delivery is marked `delivery.uncertain`; the final state comes from a provider event or the status query.

  The result is a decision: `:query`, `{:retry, mark}` (`mark` is `:uncertain` on a paid channel, else `:none`) or `{:stop, mark}`.
  """

  alias Relay.Channels.Adapter

  @type mark :: :uncertain | :none
  @type decision :: :query | {:retry, mark()} | {:stop, mark()}
  @type query_result :: Adapter.query_result()

  # T-28
  # CH-10
  # INV-9
  # INV-13
  @doc "Decides what follows an uncertain attempt from the provider's declared policy, whether the channel is paid and whether this logical send was already retried after an uncertain attempt."
  @spec decide(map(), boolean(), boolean()) :: decision()
  def decide(policy, paid?, retried?) when is_boolean(paid?) and is_boolean(retried?) do
    mark = if paid?, do: :uncertain, else: :none

    cond do
      paid? and retried? -> {:stop, mark}
      Map.get(policy, "provider_key") == true -> {:retry, mark}
      Map.get(policy, "mode") == "wait_and_query" -> :query
      Map.get(policy, "mode") == "retry_accepting_duplicate_risk" -> {:retry, mark}
      true -> {:stop, mark}
    end
  end

  # T-28
  # CH-10
  @doc "Decides what follows the status query of an uncertain attempt: a provider answer is the outcome, a request the provider never received may be sent again under the same rules, and an unavailable status endpoint leaves the attempt `unknown`."
  @spec after_query(query_result(), boolean(), boolean()) ::
          {:outcome, Adapter.result()} | {:retry, mark()} | {:stop, mark()}
  def after_query({:accepted, _info} = result, _paid?, _retried?), do: {:outcome, result}
  def after_query({:rejected, _raw} = result, _paid?, _retried?), do: {:outcome, result}

  def after_query(:not_received, paid?, retried?) do
    mark = if paid?, do: :uncertain, else: :none
    if paid? and retried?, do: {:stop, mark}, else: {:retry, mark}
  end

  def after_query(:unavailable, paid?, _retried?),
    do: {:stop, if(paid?, do: :uncertain, else: :none)}
end
