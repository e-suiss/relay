defmodule Relay.Delivery.Ledger do
  @moduledoc """
  The delivery ledger append API. Every evidence about a delivery is a row in the append-only ledger, written even when it is late (DS-2, DS-20); the projection is derived from the ledger and can be rebuilt from it at any time (INV-6, DS-3). Its four axes are kept apart: attempts, the delivery axis that only moves forward (`none < accepted < delivered`, INV-7), the failure axis with its kind, class, reason and `rule_id`, and engagement, each kind with its own first timestamp and source (DS-7).

  A delivery-axis entry that cannot raise the delivery is a late event: it stays in the ledger and is counted (`late_event_count`, DS-4 (1)). The failure axis takes the newest evidence by attempt number, provider sequence and occurrence, and, for the same attempt and failure kind, the source priority provider webhook > provider API > Relay before the receipt order (DS-4 (3)). A `delivered` of any attempt delivers the delivery and clears only the same attempt's failure; a second attempt's `delivered` sets `duplicate_delivered` (INV-8, DS-5). The axis effect of an entry is the caller's, normally from the channel's evidence table (DS-10).

  An engagement entry carries `engagement: %{kind: :seen | :read | :clicked | :archived, source: :inbox_action | :provider_signal | :client_sdk | :tracked_link, clicked_by: :human | :likely_bot}` (`clicked_by` for a click only); it moves only the engagement axis, and the caller passes the delivery rank when the evidence also proves the delivery (DS-7, DS-34).
  """

  alias Relay.Delivery.Store

  @actors [:relay, :provider_api, :provider_webhook, :client_sdk, :user]
  @events ~w(delivery.queued delivery.skipped delivery.deferred delivery.cancelled
             delivery.paused delivery.resumed delivery.held delivery.expired
             delivery.dead_lettered delivery.replay_opened delivery.uncertain
             provider.reported provider.unknown_code
             attempt.started attempt.succeeded attempt.failed attempt.unknown
             engagement.opened engagement.clicked engagement.displayed engagement.seen
             engagement.read engagement.archived)
  @failure_kinds [:skipped, :failed, :bounced, :expired, :cancelled]
  @after_delivered [:valid, :stale, :conflict]
  @engagement_kinds [:seen, :read, :clicked, :archived]
  @engagement_sources [:inbox_action, :provider_signal, :client_sdk, :tracked_link]
  @clickers [:human, :likely_bot]
  @ranks %{none: 0, accepted: 1, delivered: 2}

  @enforce_keys [:id, :delivery_id, :actor, :event_type, :occurred_at]
  defstruct [
    :id,
    :delivery_id,
    :actor,
    :event_type,
    :occurred_at,
    attempt_no: nil,
    raw_code: nil,
    provider: nil,
    provider_seq: nil,
    receipt_id: nil,
    delivery_rank: nil,
    failure_kind: nil,
    failure_class: nil,
    failure_rule_id: nil,
    after_delivered: nil,
    detail: nil,
    engagement: nil,
    traceparent: nil
  ]

  @type actor :: :relay | :provider_api | :provider_webhook | :client_sdk | :user
  @type rank :: :none | :accepted | :delivered
  @type engagement :: %{
          required(:kind) => :seen | :read | :clicked | :archived,
          required(:source) => :inbox_action | :provider_signal | :client_sdk | :tracked_link,
          optional(:clicked_by) => :human | :likely_bot
        }
  @type result ::
          :applied
          | :duplicate_ignored
          | :stale_ignored
          | :conflict_flagged
          | :delivery_not_found
          | :attempt_not_found
          | :rejected_future_timestamp

  @type t :: %__MODULE__{
          id: Relay.Id.t(),
          delivery_id: Relay.Id.t(),
          actor: actor(),
          event_type: String.t(),
          occurred_at: DateTime.t(),
          attempt_no: pos_integer() | nil,
          raw_code: String.t() | nil,
          provider: String.t() | nil,
          provider_seq: integer() | nil,
          receipt_id: Relay.Id.t() | nil,
          delivery_rank: rank() | nil,
          failure_kind: atom() | nil,
          failure_class: String.t() | nil,
          failure_rule_id: String.t() | nil,
          after_delivered: :valid | :stale | :conflict | nil,
          detail: map() | nil,
          engagement: engagement() | nil,
          traceparent: String.t() | nil
        }

  # C-32
  # DS-3
  # DS-8
  @doc "Builds a ledger entry; the actor, event name, rank, failure kind and engagement come from closed sets."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Relay.Error.t()}
  def new(attrs) do
    entry = struct!(__MODULE__, attrs)

    checks = [
      actor: entry.actor in @actors,
      event_type: entry.event_type in @events,
      delivery_rank: optional_in?(entry.delivery_rank, Map.keys(@ranks)),
      failure_kind: optional_in?(entry.failure_kind, @failure_kinds),
      after_delivered: optional_in?(entry.after_delivered, @after_delivered),
      engagement: engagement?(entry.engagement),
      occurred_at: match?(%DateTime{}, entry.occurred_at)
    ]

    case Enum.find(checks, fn {_field, ok?} -> not ok? end) do
      nil -> {:ok, entry}
      {field, false} -> invalid(field)
    end
  rescue
    error in [ArgumentError, KeyError] ->
      {:error, Relay.Error.new(:invalid_ledger_entry, Exception.message(error))}
  end

  @doc "Returns the event names of this stage's ledger."
  @spec event_types() :: [String.t(), ...]
  def event_types, do: @events

  # C-32
  # OP-3
  # OP-4
  # DS-4 (4)
  @doc "Appends an entry inside the scoped transaction and returns the outcome with the projection's rank and version."
  @spec append(t()) :: {result(), rank() | nil, non_neg_integer() | nil}
  def append(%__MODULE__{} = entry) do
    {result, rank, version} = entry |> params() |> Store.ledger_append()
    {result, rank_name(rank), version}
  end

  @doc "Returns the positional parameters of `relay_fn.ledger_append` for an entry."
  @spec params(t()) :: [term(), ...]
  def params(%__MODULE__{} = e) do
    [
      e.id,
      e.delivery_id,
      e.attempt_no,
      Atom.to_string(e.actor),
      e.event_type,
      e.raw_code,
      e.provider,
      e.provider_seq,
      e.occurred_at,
      e.receipt_id,
      e.delivery_rank && Map.fetch!(@ranks, e.delivery_rank),
      e.failure_kind && Atom.to_string(e.failure_kind),
      e.failure_class,
      e.failure_rule_id,
      e.after_delivered && Atom.to_string(e.after_delivered),
      detail(e),
      e.traceparent
    ]
  end

  defp detail(%__MODULE__{engagement: nil, detail: detail}), do: detail

  defp detail(%__MODULE__{engagement: engagement, detail: detail}) do
    value =
      for {key, field} <- engagement,
          field != nil,
          into: %{},
          do: {Atom.to_string(key), Atom.to_string(field)}

    Map.put(detail || %{}, "engagement", value)
  end

  defp engagement?(nil), do: true

  defp engagement?(%{kind: kind, source: source} = engagement) do
    clicked_by = Map.get(engagement, :clicked_by)
    clicks? = if kind == :clicked, do: clicked_by in @clickers, else: clicked_by == nil
    extra = Map.drop(engagement, [:kind, :source, :clicked_by])
    kind in @engagement_kinds and source in @engagement_sources and clicks? and extra == %{}
  end

  defp engagement?(_other), do: false

  defp optional_in?(nil, _allowed), do: true
  defp optional_in?(value, allowed), do: value in allowed

  defp rank_name(nil), do: nil

  defp rank_name(value) when is_integer(value) do
    Enum.find_value(@ranks, fn {name, rank} -> if rank == value, do: name end) ||
      raise ArgumentError, "delivery rank #{value} is outside the closed set"
  end

  defp invalid(field),
    do:
      {:error,
       Relay.Error.new(:invalid_ledger_entry, "invalid ledger entry field", %{field: field})}
end
