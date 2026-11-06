defmodule Relay.Channels.Limits do
  @moduledoc """
  The provider limits of one call, as a pure function of the provider's declaration, the route and the target (CH-17, CH-18, T-19, T-20, T-33, TN-53).

  The declaration's `limits` hold three layers, each a list of `{channel, unit, limit, per_ms, source}` rows: `account` (the account or project, such as an FCM project quota or an ESP send rate), `sender` (a number's MPS, a WhatsApp number's throughput) and `recipient` (a business–user pair, a chat, a device). Each row of the call's channel becomes one GCRA limit:

    * Relay's limit is stricter than the provider's published one (T-20 (4)): the row's `limit` times the margin of 90 %, at least 1, with the same period and a burst of the whole window. The account layer is scaled again by the adaptive factor of the account (`Relay.Channels.Throttle`, AIMD).
    * The key is the channel, the account and the layer's component (T-20 (6)): the sender identity (the account itself when the call names none), or the target's digest; on email the recipient layer is the recipient's domain (gmail.com, outlook.com), one bucket per mailbox provider.
    * The cost is in the channel's unit: SMS segments (the rendered content's `segments`, at least 1), email recipients, and one message or request elsewhere.
    * On a shared account (`ownership: shared`) the account layer is the quota every tenant shares: it is keyed by the provider only, decided in the installation scope and carries the cumulative lane ceiling (T-33), so a bulk lane stops at its share and tenants are served by the weighted DRR of the bulk lanes before they reach it (TN-53). A tenant that brings its own account is keyed in its own scope and leaves the shared quota; the ceiling applies there too, with the same formula.
  """

  alias Relay.ChannelDeclarations

  @layers ~w(account sender recipient)
  @margin_bp 9_000
  @units %{
    "message" => :message,
    "recipient" => :recipient,
    "segment" => :segment,
    "unique_recipient" => :unique_recipient,
    "request" => :request
  }

  @type check :: %{
          layer: String.t(),
          shared: boolean(),
          attrs: map(),
          key_parts: [String.t(), ...],
          cost: pos_integer()
        }

  @type call :: %{
          required(:channel) => String.t(),
          required(:account) => map(),
          required(:target) => String.t(),
          optional(:sender_id) => Relay.Id.t() | nil,
          optional(:content) => map() | binary(),
          optional(:factor) => float()
        }

  # CH-17
  # CH-18
  # T-20 (4)
  # T-20 (6)
  # T-33
  # TN-53
  @doc "The limit checks of one call in the order they are decided: account, sender, recipient. `attrs` builds the GCRA limit (`Relay.Platform.rate_limit/1`); a check is `shared` when it is decided in the installation scope with the lane ceiling."
  @spec checks(ChannelDeclarations.declaration() | nil, call()) :: [check()]
  def checks(nil, _call), do: []

  def checks(declaration, %{channel: channel, account: account} = call) do
    limits = Map.get(declaration, "limits") || %{}
    shared = account["ownership"] == "shared"

    for layer <- @layers,
        row <- Map.get(limits, layer, []),
        row["channel"] == channel,
        parts = parts(layer, call, shared),
        {limit, period} <- [bounds(row, layer, Map.get(call, :factor, 1.0))] do
      %{
        layer: layer,
        shared: shared and layer == "account",
        attrs: %{
          id: "provider." <> layer,
          algorithm: :gcra,
          unit: Map.get(@units, row["unit"], :message),
          limit: limit,
          period_ms: period,
          burst: limit,
          ceiling: layer == "account"
        },
        key_parts: parts,
        cost: cost(channel, Map.get(call, :content))
      }
    end
  end

  defp bounds(row, layer, factor) do
    base = div(row["limit"] * @margin_bp, 10_000)
    scaled = if layer == "account", do: trunc(base * factor), else: base
    {max(scaled, 1), row["per_ms"]}
  end

  defp parts("account", call, true), do: [call.channel, call.account["provider"]]
  defp parts("account", call, false), do: [call.channel, id(call.account["id"])]

  defp parts("sender", call, _shared) do
    sender = Map.get(call, :sender_id) || call.account["id"]
    [call.channel, id(call.account["id"]), id(sender)]
  end

  defp parts("recipient", call, _shared),
    do: [call.channel, id(call.account["id"]), bucket(call.channel, call.target)]

  # CH-17
  @doc "The recipient bucket of a target: on email the recipient's domain, elsewhere the digest of the target."
  @spec bucket(String.t(), String.t()) :: String.t()
  def bucket("email", address) do
    case address |> String.downcase() |> String.split("@") do
      [_local, domain] when byte_size(domain) in 1..128 -> domain
      _other -> digest(address)
    end
  end

  def bucket(_channel, target), do: digest(target)

  defp digest(value),
    do: :sha256 |> :crypto.hash(value) |> binary_part(0, 16) |> Base.encode16(case: :lower)

  defp id(nil), do: "none"
  defp id(<<_::128>> = id), do: Base.encode16(id, case: :lower)
  defp id(text) when is_binary(text), do: text

  # CH-17
  # T-19
  @doc "The cost of one call in the channel's unit: SMS segments, email recipients, otherwise one."
  @spec cost(String.t(), map() | binary() | nil) :: pos_integer()
  def cost("sms", %{"segments" => n}) when is_integer(n) and n > 0, do: n
  def cost("sms", %{segments: n}) when is_integer(n) and n > 0, do: n
  def cost(_channel, _content), do: 1
end
