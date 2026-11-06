defmodule Relay.Channels.Fake do
  @moduledoc """
  The fake provider adapter (X-25, X-26, API-63, TN-7). On the test plane, and in `shadow` mode, the whole pipeline runs with the same code and the same `rule_id`s as on the live plane, and only this last step differs: the answer comes from the simulated result table (`Relay.Channels.Simulated`, CH-72) by the target address, with no network call. Its declaration is `priv/channels/fake/` and passes the same activation gate as every adapter. The simulated provider has no panel, so its settings check always holds (CH-52).
  """

  @behaviour Relay.Channels.Adapter

  alias Relay.Channels.Request
  alias Relay.Channels.Simulated

  @channels ~w(push web_push email sms voice whatsapp slack teams telegram discord)

  @impl Relay.Channels.Adapter
  def provider, do: "fake"

  @impl Relay.Channels.Adapter
  def channels, do: @channels

  # CH-72
  # X-26
  @impl Relay.Channels.Adapter
  def deliver(%Request{} = request) do
    case Simulated.answer(result(request)) do
      {:accepted, info} -> {:accepted, Map.put(info, :provider_message_id, message_id(request))}
      other -> other
    end
  end

  # T-28
  @impl Relay.Channels.Adapter
  def query(%Request{} = request) do
    case Simulated.answer(result(request)) do
      {:accepted, info} -> {:accepted, Map.put(info, :provider_message_id, message_id(request))}
      {:rejected, raw} -> {:rejected, raw}
      _uncertain -> :not_received
    end
  end

  # CH-52
  @impl Relay.Channels.Adapter
  def check_settings(%{account: %{}}), do: :ok

  defp result(request) do
    value = Relay.Redacted.expose(request.target.value)
    Simulated.result(Simulated.kind(request.channel), value)
  end

  defp message_id(request), do: "sim_" <> request.idempotency_key
end
