defmodule Relay.Channels.Request do
  @moduledoc """
  One provider call of a delivery attempt, as the core hands it to a channel adapter (`c:Relay.Channels.Adapter.deliver/1`).

    * `scope`, `delivery_id`, `attempt_no`: the attempt; `channel` and `provider` the route.
    * `idempotency_key`: the provider idempotency key, stable across the attempts of the logical send (INV-13, OP-6 (4)); an adapter sends it in the provider's key or correlation field.
    * `target`: `%{kind: :address | :device | :endpoint, id: id | nil, value: Relay.Redacted.t()}`, the address, token or endpoint the provider sends to; a device target also carries `device`, its `platform`, `app`, `apns_environment` and redacted Web Push `keys`.
    * `content`: the rendered content of the delivery's channel cell, as the renderer encodes it.
    * `credentials`: the provider credential resolved from the secret backend for this call only, or `nil`; never cached by the adapter (TN-26).
    * `account`: the provider connection the route chose (`id`, `ownership`, `settings`), or `nil`.
    * `sender`: the verified sender identity of the route, or `nil`.
    * `ttl_s`: the channel time to live derived from the message's `expires_at` (`Relay.Channels.ttl_s/2`, CH-9), `nil` without `expires_at`.
    * `timeout_ms`: the call timeout, the shortest of the message, channel and provider layers (CH-9); the adapter never waits longer.
    * `message_class`, `test?` (the test plane) and `overrides`: the delivery's channel block of overrides by the precedence request > step > workflow (API-23), such as `"from"` on e-mail or `"raw"` on push and WhatsApp; the request's own block is read from the event's sealed payload.
    * `push`: the push policy the channel step decided (`Relay.Channels.Push.Policy`), `nil` on the other channels.
    * `encoding`: on SMS the explicit encoding of the send, `"GSM7"`, `"GSM7_TR"` or `"UCS2"` (CH-48); the adapter names it to the provider and never leaves it to the provider's detection.
    * `product`: the provider product, `"otp"` for a `security` message on a provider with an OTP product, otherwise `"standard"` (CH-53).
    * `update`: on a channel that updates messages, the provider message reference of the earlier message about the same subject in the same conversation, which the adapter edits in place instead of posting a new one (CH-23), or `nil`.
  """

  @enforce_keys [
    :scope,
    :delivery_id,
    :attempt_no,
    :channel,
    :provider,
    :idempotency_key,
    :target,
    :timeout_ms
  ]
  defstruct [
    :scope,
    :delivery_id,
    :attempt_no,
    :channel,
    :provider,
    :idempotency_key,
    :target,
    :timeout_ms,
    content: %{},
    credentials: nil,
    account: nil,
    sender: nil,
    ttl_s: nil,
    message_class: nil,
    test?: false,
    overrides: %{},
    push: nil,
    encoding: nil,
    product: "standard",
    update: nil
  ]

  @type target :: %{
          required(:kind) => :address | :device | :endpoint,
          required(:id) => Relay.Id.t() | nil,
          required(:value) => Relay.Redacted.t(),
          optional(:device) => map()
        }

  @type t :: %__MODULE__{
          scope: Relay.Scope.t(),
          delivery_id: Relay.Id.t(),
          attempt_no: pos_integer(),
          channel: String.t(),
          provider: String.t(),
          idempotency_key: String.t(),
          target: target(),
          timeout_ms: pos_integer(),
          content: map() | binary(),
          credentials: Relay.Redacted.t() | nil,
          account: map() | nil,
          sender: map() | nil,
          ttl_s: non_neg_integer() | nil,
          message_class: String.t() | nil,
          test?: boolean(),
          overrides: map(),
          push: map() | nil,
          encoding: String.t() | nil,
          product: String.t(),
          update: String.t() | nil
        }
end
