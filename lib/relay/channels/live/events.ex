defmodule Relay.Channels.Live.Events do
  @moduledoc """
  Records an event a provider reports after the call: a delivery receipt, a bounce, a complaint, a read, a status query answer (DS-10, DS-6, INV-5). It is the entry point of every adapter's webhook or receipt handler, which verifies the request first (`Relay.Channels.verify_*`) and then passes the event here.

  The event code is looked up in the provider's `channel_event_evidence` rows of the active declarations; an event code without a row is rejected (DS-10 (1)) and never changes the projection: it is written to the ledger as `provider.unknown_code` with its raw code, and raises the `provider.unknown_code` event and the alarm (DS-10 (2)). The row decides the ledger entry: `sets_delivery` raises the delivery axis, `sets_failure` sets the failure axis, `after_delivered` says what a failure after delivery means (DS-6) and `scope: attempt` binds the event to the delivery's latest attempt. A provider code given with the event is classified through the adapter's mapping; a code without a mapping is `unknown` and raises `provider.unknown_code` (CH-8). Group and detail both reach the append-only ledger as a `provider.reported` entry with the event code, the raw code and, when the provider sends one, its raw price object (CH-18). The entry carries the current trace context, the event's own trace, and a short `provider event` span links it to the delivery's trace (OP-34); an event of a delivery the provider accepted emits `[:relay, :provider, :event]` with the delay since the acceptance (DS-41, CH-47). The row's `side_effect` and `decision_grade` are returned for the caller: a side effect such as `add_suppression` or `deactivate_device` is the caller's to apply, and only a `reliable` event may feed an engagement decision.
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
  # DS-46
  # CH-8
  # CH-18
  @doc "Records a provider event of a delivery; see the module documentation. Returns the ledger result with the evidence row's side effect and decision grade, `{:error, :unknown_event}` for an event code without an evidence row and `{:error, :delivery_not_found}`."
  @spec record(Relay.Scope.t(), event()) ::
          {:ok, recorded()} | {:error, :unknown_event | :delivery_not_found | term()}
  def record(scope, %{delivery_id: delivery_id} = event) do
    read = fn _status -> Store.delivery(delivery_id) end

    with {:ok, declarations} <- Relay.Datasets.channel_declarations(),
         {:ok, %{} = delivery} <- Store.in_scope(scope, read) do
      case evidence(declarations, event) do
        {:ok, row} -> append(scope, event, row, delivery, classify(scope, declarations, event))
        {:error, :unknown_event} -> unknown(scope, event)
      end
    else
      {:ok, nil} -> {:error, :delivery_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp unknown(scope, event) do
    code = Map.get(event, :raw_code) || event.event_code
    _ = Relay.Channels.report_unknown_code(scope, event.provider, event.channel, code)

    {:ok, entry} =
      Relay.Delivery.ledger_entry(
        id: Relay.Id.generate(),
        delivery_id: event.delivery_id,
        actor: Map.get(event, :actor, :provider_webhook),
        event_type: "provider.unknown_code",
        occurred_at: Map.get_lazy(event, :occurred_at, &Relay.Clock.utc_now/0),
        raw_code: String.slice(code, 0, 128),
        provider: event.provider,
        provider_seq: Map.get(event, :provider_seq),
        detail: detail(event)
      )

    _ = Relay.Delivery.append_ledger(scope, entry)
    {:error, :unknown_event}
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

  defp append(scope, event, row, delivery, class) do
    failure_kind = Map.get(@failure_kinds, row["sets_failure"])
    attempt_no = if row["scope"] == "attempt", do: positive(delivery["attempt_count"])

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
        detail: detail(event),
        traceparent: Relay.Trace.current()
      )

    case Relay.Delivery.append_ledger(scope, entry) do
      {:ok, {result, _rank, _version}} ->
        observe(event, delivery)

        {:ok,
         %{
           result: result,
           side_effect: row["side_effect"],
           decision_grade: row["decision_grade"],
           failure_class: class
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # DS-40
  # DS-41
  # OP-34
  # CH-47
  defp observe(event, delivery) do
    now = Relay.Clock.utc_now()
    current = Relay.Trace.current()

    Relay.Trace.record(%{
      name: "provider event",
      kind: :consumer,
      traceparent: Relay.Trace.child(current),
      parent_span_id: Relay.Trace.span_id(current),
      started_at: now,
      ended_at: now,
      attributes: %{
        "relay.channel" => event.channel,
        "relay.provider" => event.provider,
        "relay.event_type" => event.event_code
      },
      links: List.wrap(delivery["traceparent"]),
      error?: false
    })

    case delivery["accepted_at"] do
      %DateTime{} = accepted_at ->
        delay_ms = max(DateTime.diff(now, accepted_at, :millisecond), 0)
        meta = %{channel: event.channel, provider: event.provider}
        :telemetry.execute([:relay, :provider, :event], %{delay_ms: delay_ms}, meta)

      _not_accepted ->
        :ok
    end
  end

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
