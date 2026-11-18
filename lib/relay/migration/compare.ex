defmodule Relay.Migration.Compare do
  @moduledoc """
  The layered comparison of shadow mode (OP-52 (4), OP-94), pure. A comparison holds up to three sides of one request, channel and recipient: the existing system's report (`legacy`), Relay's decision (`relay`) and what Relay's shadow send would have sent (`delivery`). Each side is a map of masked or digested values.

    * The decision layer compares `decision`, `consent`, `timing`, `dedup_key` (only when the existing system named one) and `schedule`; a recipient on one side only differs in `recipients`.
    * The content layer compares the canonical content digests when both sides sent.
    * The routing layer compares the `provider` and the `sender` when both sides name one.

  A send to a recipient whose consent the other side refused or suppressed is `unpermitted`: a single one stops a rollout (OP-80).
  """

  @refused ~w(refused suppressed)

  @type side :: %{optional(String.t()) => term()} | nil
  @type outcome :: %{
          state: :pending | :matched | :differs,
          decision_match: boolean() | nil,
          content_match: boolean() | nil,
          routing_match: boolean() | nil,
          differing: [String.t()],
          unpermitted: boolean()
        }

  # OP-52 (4)
  # OP-80
  # OP-94
  @doc "Compares the sides of one comparison; `final?` tells that a missing side will not come any more, which makes it a recipient set difference."
  @spec compare(side(), side(), side(), boolean()) :: outcome()
  def compare(legacy, relay, delivery, final? \\ false)

  def compare(%{} = legacy, %{} = relay, delivery, _final?) do
    decision = decision(legacy, relay)
    content = content(legacy, relay, delivery)
    routing = routing(legacy, delivery)
    differing = decision ++ content ++ routing

    %{
      state: if(differing == [], do: :matched, else: :differs),
      decision_match: decision == [],
      content_match: match(content, legacy, relay, delivery, &content_known?/3),
      routing_match: match(routing, legacy, relay, delivery, &routing_known?/3),
      differing: differing,
      unpermitted: unpermitted?(legacy, relay)
    }
  end

  def compare(_legacy, _relay, _delivery, true) do
    %{
      state: :differs,
      decision_match: false,
      content_match: nil,
      routing_match: nil,
      differing: ["recipients"],
      unpermitted: false
    }
  end

  def compare(_legacy, _relay, _delivery, false) do
    %{
      state: :pending,
      decision_match: nil,
      content_match: nil,
      routing_match: nil,
      differing: [],
      unpermitted: false
    }
  end

  # OP-94
  @doc "Relay's decision side of a delivery row: its decision, the consent and timing outcome read from its rule, the digest of its dedup key and its schedule."
  @spec relay_side(map()) :: map()
  def relay_side(row) do
    rule = row["decision_rule_id"] || ""

    %{
      "decision" => decision_name(row["decision"]),
      "consent" => consent(rule),
      "timing" => timing(rule),
      "dedup_key" => digest(row["dedup_key"]),
      "schedule" => schedule(row["send_at"])
    }
  end

  # OP-94
  @doc "The existing system's side of one outcome of a reported channel."
  @spec legacy_side(map(), map(), map()) :: map()
  def legacy_side(observation, channel, outcome) do
    %{
      "decision" => outcome["decision"],
      "consent" => outcome["consent"],
      "timing" => outcome["timing"],
      "dedup_key" => digest(observation["dedup_key"]),
      "schedule" => schedule(observation["scheduled_at"]),
      "content" => channel["content_digest"],
      "provider" => channel["provider"],
      "sender" => digest(channel["sender"])
    }
  end

  # OP-94
  @doc "The delivery side of a shadow send: its content digest, the provider its real route would take and the digest of its sender."
  @spec delivery_side(String.t() | nil, String.t() | nil, String.t() | nil) :: map()
  def delivery_side(content_digest, provider, sender),
    do: %{"content" => content_digest, "provider" => provider, "sender" => digest(sender)}

  # OP-94
  @doc "The lowercase hex SHA-256 of a text, `nil` for `nil`."
  @spec digest(String.t() | nil) :: String.t() | nil
  def digest(nil), do: nil

  def digest(text) when is_binary(text),
    do: Base.encode16(:crypto.hash(:sha256, text), case: :lower)

  defp decision(legacy, relay) do
    fields =
      for field <- ~w(decision consent timing), legacy[field] != relay[field], do: field

    dedup =
      if legacy["dedup_key"] != nil and legacy["dedup_key"] != relay["dedup_key"],
        do: ["dedup_key"],
        else: []

    schedule = if legacy["schedule"] != relay["schedule"], do: ["schedule"], else: []
    fields ++ dedup ++ schedule
  end

  defp content(legacy, relay, delivery) do
    if content_known?(legacy, relay, delivery) and legacy["content"] != delivery["content"],
      do: ["content"],
      else: []
  end

  defp routing(legacy, delivery) when is_map(delivery) do
    for field <- ~w(provider sender),
        legacy[field] != nil and delivery[field] != nil,
        legacy[field] != delivery[field],
        do: field
  end

  defp routing(_legacy, _delivery), do: []

  defp match([], legacy, relay, delivery, known?),
    do: if(known?.(legacy, relay, delivery), do: true, else: nil)

  defp match(_differing, _legacy, _relay, _delivery, _known?), do: false

  defp content_known?(legacy, relay, delivery) do
    legacy["decision"] == "sent" and relay["decision"] == "sent" and is_map(delivery) and
      is_binary(legacy["content"]) and is_binary(delivery["content"])
  end

  defp routing_known?(legacy, _relay, delivery) do
    is_map(delivery) and
      ((legacy["provider"] != nil and delivery["provider"] != nil) or
         (legacy["sender"] != nil and delivery["sender"] != nil))
  end

  defp unpermitted?(legacy, relay) do
    (legacy["decision"] == "sent" and relay["consent"] in @refused) or
      (relay["decision"] == "sent" and legacy["consent"] in @refused)
  end

  defp decision_name("send"), do: "sent"
  defp decision_name("skip"), do: "skipped"
  defp decision_name("defer"), do: "deferred"
  defp decision_name(other), do: other

  defp consent("suppression." <> _rest), do: "suppressed"
  defp consent("consent." <> _rest), do: "refused"
  defp consent("iys." <> _rest), do: "refused"
  defp consent(_rule), do: "allowed"

  defp timing("quiet_hours." <> _rest), do: "quiet_hours"
  defp timing("dnd." <> _rest), do: "quiet_hours"
  defp timing("tenant_timezone_window." <> _rest), do: "quiet_hours"
  defp timing("frequency." <> _rest), do: "frequency"
  defp timing("throttle." <> _rest), do: "throttle"
  defp timing(_rule), do: "none"

  defp schedule(%DateTime{} = at), do: DateTime.to_iso8601(%{at | microsecond: {0, 0}})

  defp schedule(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> schedule(at)
      _error -> nil
    end
  end

  defp schedule(_none), do: nil
end
