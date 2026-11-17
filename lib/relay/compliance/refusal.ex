defmodule Relay.Compliance.Refusal do
  @moduledoc """
  One refusal of a recipient, as data (PC-38, PC-39). Its scope says how far it reaches and decides what applying it writes:

  | Scope | Reach | Written in Relay | Kind |
  |---|---|---|---|
  | `category` | the category of one message on one channel | a preference `opt_out` of the category on the channel (writer `unsubscribe`) | preference |
  | `all_marketing` | every marketing category of the brand on the channel | the consent copy `REVOKED` (writer `relay`) for the brand and channel | refusal notice |
  | `all_channel` | everything on the channel | the consent copy `REVOKED` and a `refusal` suppression of the address | refusal notice |

  A category exit is a preference and is never written to the consent copy; a refusal notice is never written as a preference. The two are not reduced to one switch (PC-38), and the lattice reads them apart: a refusal notice is gate 1c (`consent.revoked`) and gate 1b, a preference is filter 3b.

  The sources and their default scopes (PC-39): `rfc8058`, `unsubscribe_link` and `mailto` are the exits of one message and always have the `category` scope; `unsubscribe_page` (the page's "no commercial e-mail from this brand") and `complaint` default to `all_marketing`, `sms_keyword` to `all_channel`, `whatsapp` and `iys` to `all_marketing`. Every refusal carries its evidence: the source, the time and, where the request has them, the requesting address and user agent, redacted. A refusal notice is handed to the refusal sink once applied, except one that came from the registry itself (`iys`).
  """

  @exits ~w(rfc8058 unsubscribe_link mailto)
  @defaults %{
    "rfc8058" => "category",
    "unsubscribe_link" => "category",
    "mailto" => "category",
    "unsubscribe_page" => "all_marketing",
    "sms_keyword" => "all_channel",
    "complaint" => "all_marketing",
    "whatsapp" => "all_marketing",
    "iys" => "all_marketing"
  }
  @scopes ~w(category all_marketing all_channel)
  @channels ~w(email sms voice whatsapp)

  @enforce_keys [:recipient_id, :channel, :source, :scope, :ref, :occurred_at, :actor_ref]
  defstruct [
    :recipient_id,
    :channel,
    :source,
    :scope,
    :ref,
    :occurred_at,
    :actor_ref,
    category: nil,
    brand_subtenant_id: nil,
    ip: nil,
    user_agent: nil,
    address: nil
  ]

  @type t :: %__MODULE__{
          recipient_id: Relay.Id.t(),
          channel: String.t(),
          source: String.t(),
          scope: String.t(),
          ref: String.t(),
          occurred_at: DateTime.t(),
          actor_ref: String.t(),
          category: String.t() | nil,
          brand_subtenant_id: Relay.Id.t() | nil,
          ip: Relay.Redacted.t() | nil,
          user_agent: Relay.Redacted.t() | nil,
          address: Relay.Redacted.t() | nil
        }

  # PC-39
  @doc "Every refusal source."
  @spec sources() :: [String.t(), ...]
  def sources, do: Map.keys(@defaults)

  # PC-39
  @doc "Every refusal scope."
  @spec scopes() :: [String.t(), ...]
  def scopes, do: @scopes

  # PC-39
  @doc "The scope a refusal of `source` has when none is given; `nil` for an unknown source."
  @spec default_scope(String.t()) :: String.t() | nil
  def default_scope(source), do: Map.get(@defaults, source)

  # PC-38
  @doc "Whether the refusal is a refusal notice; a `category` exit is a preference."
  @spec notice?(t()) :: boolean()
  def notice?(%__MODULE__{scope: scope}), do: scope != "category"

  # PC-38
  @doc "Whether the applied refusal is handed to the refusal sink: a refusal notice that did not come from the registry."
  @spec forwarded?(t()) :: boolean()
  def forwarded?(%__MODULE__{source: source} = refusal), do: notice?(refusal) and source != "iys"

  # PC-38
  # PC-39
  @doc "Describes a refusal from `attrs`; see `Relay.Compliance.refuse/2`."
  @spec new(map()) :: {:ok, t()} | {:error, Relay.Error.t()}
  def new(attrs) when is_map(attrs) do
    source = Map.get(attrs, :source)
    scope = Map.get(attrs, :scope) || default_scope(source)
    evidence = Map.get(attrs, :evidence) || %{}

    refusal = %__MODULE__{
      recipient_id: Map.get(attrs, :recipient_id),
      channel: Map.get(attrs, :channel),
      source: source,
      scope: scope,
      ref: Map.get(attrs, :ref),
      occurred_at: Map.get(attrs, :occurred_at) || Relay.Clock.utc_now(),
      actor_ref: Map.get(attrs, :actor_ref) || "relay:" <> to_string(source),
      category: Map.get(attrs, :category),
      brand_subtenant_id: Map.get(attrs, :brand_subtenant_id),
      ip: Map.get(evidence, :ip),
      user_agent: Map.get(evidence, :user_agent),
      address: Map.get(attrs, :address)
    }

    case problem(refusal) do
      nil -> {:ok, refusal}
      message -> {:error, Relay.Error.new(:validation_failed, message)}
    end
  end

  defp problem(refusal) do
    Enum.find_value(checks(refusal), fn {valid?, message} -> if not valid?, do: message end)
  end

  defp checks(r) do
    [
      {match?(<<_::128>>, r.recipient_id), "a refusal names its recipient"},
      {r.channel in @channels, "a refusal names a channel that takes consent"},
      {is_map_key(@defaults, r.source), "an unknown refusal source"},
      {r.scope in @scopes, "an unknown refusal scope"},
      {r.source not in @exits or r.scope == "category", "an exit of one message is a category"},
      {text?(r.category, 128) == (r.scope == "category"), "only a category refusal names one"},
      {text?(r.ref, 256), "a refusal carries the reference of its request"},
      {text?(r.actor_ref, 256), "a refusal names who recorded it"},
      {match?(%DateTime{}, r.occurred_at), "a refusal has its time"},
      {is_nil(r.brand_subtenant_id) or match?(<<_::128>>, r.brand_subtenant_id),
       "the brand is a sub-tenant"},
      {Enum.all?([r.ip, r.user_agent, r.address], &redacted?/1), "personal evidence is redacted"}
    ]
  end

  defp text?(value, max), do: is_binary(value) and value != "" and String.length(value) <= max

  defp redacted?(nil), do: true
  defp redacted?(value), do: Relay.Redacted.redacted?(value)
end
