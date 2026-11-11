defmodule Relay.Channels.Live.Events do
  @moduledoc """
  Records an event a provider reports after the call: a delivery receipt, a bounce, a complaint, a read, a status query answer (DS-10, DS-6, INV-5). It is the entry point of every adapter's webhook or receipt handler, which verifies the request first (`Relay.Channels.verify_*`) and then passes the event here.

  The event code is looked up in the provider's `channel_event_evidence` rows of the active declarations; an event code without a row is rejected (DS-10 (1)). The row decides the ledger entry: `sets_delivery` raises the delivery axis, `sets_failure` sets the failure axis, `after_delivered` says what a failure after delivery means (DS-6) and `scope: attempt` binds the event to the delivery's latest attempt. A provider code given with the event is classified through the adapter's mapping; a code without a mapping is `unknown` and raises `provider.unknown_code` (CH-8). Group and detail both reach the append-only ledger as a `provider.reported` entry with the event code, the raw code and, when the provider sends one, its raw price object (CH-18). The row's `side_effect` and `decision_grade` are returned for the caller: a side effect such as `add_suppression` or `deactivate_device` is the caller's to apply, and only a `reliable` event may feed an engagement decision.
  """

  alias Relay.ChannelDeclarations
  alias Relay.Channels.Live.Store

  @ranks %{"accepted" => :accepted, "delivered" => :delivered}
  @failure_kinds %{
    "skipped" => :skipped,
    "failed" => :failed,
    "bounced" => :bounced,
    "expired" => :expired,
    "cancelled" => :cancelled
  }
  @after_delivered %{"valid" => :valid, "stale" => :stale, "conflict" => :conflict}
  @unwritten [:delivery_not_found, :attempt_not_found, :rejected_future_timestamp]

  @type event :: %{
          required(:delivery_id) => Relay.Id.t(),
          required(:provider) => String.t(),
          required(:channel) => String.t(),
          required(:event_code) => String.t(),
          optional(:occurred_at) => DateTime.t(),
          optional(:actor) => :provider_webhook | :provider_api,
          optional(:raw_code) => String.t() | nil,
          optional(:provider_seq) => integer() | nil,
          optional(:receipt_id) => Relay.Id.t() | nil,
          optional(:price) => map() | nil,
          optional(:detail) => map()
        }
  @type recorded :: %{
          result: atom(),
          side_effect: String.t(),
          decision_grade: String.t(),
          failure_class: String.t() | nil
        }

  # DS-10
  # DS-6
  # CH-8
  # CH-18
  @doc "Records a provider event of a delivery; see the module documentation. Returns the ledger result with the evidence row's side effect and decision grade, `{:error, :unknown_event}` for an event code without an evidence row and `{:error, :delivery_not_found}`."
  @spec record(Relay.Scope.t(), event()) ::
          {:ok, recorded()} | {:error, :unknown_event | :delivery_not_found | term()}
  def record(scope, %{delivery_id: _delivery_id} = event) do
    case record_many(scope, [event]) do
      {:ok, [result]} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  # T-41
  # WH-49
  # DS-10
  # CH-8
  @doc "Records several provider events of one scope in one transaction, the write of the delivery report batcher (T-41). Each event is read and recorded as `record/2` does; the result list follows the order of `events`. An event whose receipt (`receipt_id`) produces no ledger entry, for an unknown event code, an unknown delivery or attempt or a future timestamp, has its receipt marked `rejected` in the same transaction."
  @spec record_many(Relay.Scope.t(), [event()]) ::
          {:ok, [{:ok, recorded()} | {:error, :unknown_event | :delivery_not_found}]}
          | {:error, term()}
  def record_many(_scope, []), do: {:ok, []}

  def record_many(scope, events) when is_list(events) do
    with {:ok, declarations} <- Relay.Datasets.channel_declarations() do
      planned = Enum.map(events, &plan(scope, declarations, &1))
      ids = events |> Enum.map(& &1.delivery_id) |> Enum.uniq()

      Store.in_scope(scope, fn _status ->
        attempts = Store.delivery_attempts(ids)
        Enum.map(planned, &write(&1, attempts))
      end)
    end
  end

  defp plan(scope, declarations, event) do
    case evidence(declarations, event) do
      {:ok, row} -> {:ok, event, row, classify(scope, declarations, event)}
      {:error, _reason} -> {:error, event, :unknown_event}
    end
  end

  defp evidence(declarations, event) do
    ChannelDeclarations.evidence(declarations, event.provider, event.channel, event.event_code)
  end

  defp classify(scope, declarations, event) do
    case Map.get(event, :raw_code) do
      nil ->
        nil

      code ->
        case ChannelDeclarations.mapping(declarations, event.provider, code) do
          {:ok, mapping} ->
            mapping["class"]

          :unmapped ->
            _ = Relay.Channels.report_unknown_code(scope, event.provider, event.channel, code)
            "unknown"
        end
    end
  end

  defp write({:error, event, reason}, _attempts) do
    reject(event, reason)
    {:error, reason}
  end

  defp write({:ok, event, row, class}, attempts) do
    case Map.fetch(attempts, event.delivery_id) do
      {:ok, attempt_count} -> append(event, row, attempt_count, class)
      :error -> write({:error, event, :delivery_not_found}, attempts)
    end
  end

  defp append(event, row, attempt_count, class) do
    failure_kind = Map.get(@failure_kinds, row["sets_failure"])
    attempt_no = if row["scope"] == "attempt", do: positive(attempt_count)

    {:ok, entry} =
      Relay.Delivery.ledger_entry(
        id: Relay.Id.generate(),
        delivery_id: event.delivery_id,
        attempt_no: attempt_no,
        actor: Map.get(event, :actor, :provider_webhook),
        event_type: "provider.reported",
        occurred_at: Map.get_lazy(event, :occurred_at, &Relay.Clock.utc_now/0),
        raw_code: Map.get(event, :raw_code),
        provider: event.provider,
        provider_seq: Map.get(event, :provider_seq),
        receipt_id: Map.get(event, :receipt_id),
        delivery_rank: Map.get(@ranks, row["sets_delivery"]),
        failure_kind: failure_kind,
        failure_class: if(failure_kind, do: class || "unknown"),
        after_delivered: Map.get(@after_delivered, row["after_delivered"]),
        detail: detail(event)
      )

    {result, _rank, _version} = Relay.Delivery.ledger_append(entry)
    if result in @unwritten, do: reject(event, Atom.to_string(result))

    {:ok,
     %{
       result: result,
       side_effect: row["side_effect"],
       decision_grade: row["decision_grade"],
       failure_class: class
     }}
  end

  defp reject(%{receipt_id: <<_::128>> = receipt_id}, reason) do
    _ = Relay.Webhooks.receipt_mark(receipt_id, :rejected, to_string(reason))
    :ok
  end

  defp reject(_event, _reason), do: :ok

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_n), do: nil

  defp detail(event) do
    own = Map.get(event, :detail, %{})

    case Map.get(event, :price) do
      nil -> Map.put(own, "event_code", event.event_code)
      price -> Map.merge(own, %{"event_code" => event.event_code, "price" => price})
    end
  end
end
