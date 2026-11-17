defmodule Relay.Compliance.RefusalSink do
  @moduledoc """
  Where a refusal notice goes after it is applied in Relay (PC-38): the commercial message registry of the recipient's country. The sink is called from the job the applying transaction queued, never inside that transaction, and at least once for every applied notice, so it must accept a repeat. The module is configured as `config :relay, Relay.Compliance, sink: Module`; without one nothing is written anywhere else.
  """

  @typedoc "An applied refusal notice: the brand (the sub-tenant, or `nil` for the tenant), the channel, the refused address, the recipient's legal type when it is known, the source of the notice and its time."
  @type notice :: %{
          brand: Relay.Id.t() | nil,
          channel: String.t(),
          address: Relay.Redacted.t(),
          recipient_type: String.t() | nil,
          source: String.t(),
          occurred_at: DateTime.t()
        }

  @doc "Takes an applied refusal notice; an error is retried by the job."
  @callback refused(Relay.Scope.t(), notice()) :: :ok | {:error, term()}

  # PC-38
  @doc "The configured sink; `Relay.Compliance.RefusalSink.None` when there is none."
  @spec sink() :: module()
  def sink, do: Relay.Compliance.config(:sink, Relay.Compliance.RefusalSink.None)
end
