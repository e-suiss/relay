defmodule Relay.Delivery.Ledger do
  @moduledoc """
  The delivery ledger append API. Every evidence about a delivery is a row in the append-only ledger, written even when it is late; the projection on the delivery moves only forward on the delivery axis, and the failure axis takes the newest evidence by attempt, provider sequence, occurrence and receipt. The axis effect of an entry is given by the caller in this stage; source precedence comes later.
  """

  alias Relay.Delivery.Store

  @actors [:relay, :provider_api, :provider_webhook, :client_sdk, :user]
  @events ~w(delivery.queued delivery.skipped delivery.deferred delivery.cancelled
             delivery.paused delivery.resumed delivery.held delivery.expired
             delivery.dead_lettered delivery.replay_opened
             attempt.started attempt.succeeded attempt.failed attempt.unknown)
  @failure_kinds [:skipped, :failed, :bounced, :expired, :cancelled]
  @after_delivered [:valid, :stale, :conflict]
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
    traceparent: nil
  ]

  @type actor :: :relay | :provider_api | :provider_webhook | :client_sdk | :user
  @type rank :: :none | :accepted | :delivered
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
          traceparent: String.t() | nil
        }

  # C-32
  # DS-8
  @doc "Builds a ledger entry; the actor, event name, rank and failure kind come from closed sets."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Relay.Error.t()}
  def new(attrs) do
    entry = struct!(__MODULE__, attrs)

    checks = [
      actor: entry.actor in @actors,
      event_type: entry.event_type in @events,
      delivery_rank: optional_in?(entry.delivery_rank, Map.keys(@ranks)),
      failure_kind: optional_in?(entry.failure_kind, @failure_kinds),
      after_delivered: optional_in?(entry.after_delivered, @after_delivered),
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
      e.detail,
      e.traceparent
    ]
  end

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
