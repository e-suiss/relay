defmodule Relay.Channels.UnifiedPush do
  @moduledoc """
  The UnifiedPush adapter for Android devices without Google services (CH-1, §12.5.4). A UnifiedPush endpoint is an RFC 8030 push resource of the distributor the user chose, so the adapter shares the Web Push module (`Relay.Channels.WebPush`): the same `aes128gcm` encryption to the subscription keys, `TTL`, `Urgency` and `Topic`. VAPID is optional for a distributor: it is sent when the account carries the application's VAPID identity.

  The settings check is the Web Push identity check (`Relay.Channels.WebPush.check_vapid/2`); an account without a VAPID identity has nothing to check and holds (CH-14, CH-52).
  """

  @behaviour Relay.Channels.Adapter

  alias Relay.Channels.Push.Failures
  alias Relay.Channels.Request

  @impl Relay.Channels.Adapter
  def provider, do: "unified_push"

  @impl Relay.Channels.Adapter
  def channels, do: ["push"]

  # CH-1
  @impl Relay.Channels.Adapter
  def deliver(%Request{} = request),
    do: Relay.Channels.WebPush.deliver_push(request, __MODULE__, false)

  # DS-11
  @impl Relay.Channels.Adapter
  def decode(response), do: %{code: Failures.code(:web_push, response)}

  # CH-14
  # CH-52
  @impl Relay.Channels.Adapter
  def check_settings(%{account: account}), do: Relay.Channels.WebPush.check_vapid(account, false)
end
