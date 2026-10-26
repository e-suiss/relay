defmodule Relay.Agents.Waitpoint do
  @moduledoc """
  The waitpoint core (C-72, T-24, AG-4, AG-9…AG-16, AG-64). A waitpoint is a row and a timer: it holds no queue slot, process or memory while it waits (C-8, WF-43). Its deadline is required, at most 30 days ahead in business time, written at the first park and kept on a retry with the same identifier (AG-9); the API layer maps the required Idempotency-Key to that identifier. The waiter is an agent or an API client, and its result events and early-response buffer live in the waiter's mailbox, opened lazily (AG-64).

  Matching is two-stage (AG-14): the first stage is the exact `(tenant, environment, event type, correlation key)` index, without wildcards or prefixes; the second-stage condition language arrives with workflows, until then a condition is refused with `:condition_unsupported`. An event that matches nothing is buffered in the named waiter's mailbox (AG-13) or recorded with `rule_id = waitpoint.no_match`. Opening a waitpoint and offering an event take the same advisory lock, so an event that arrives while the waitpoint opens is neither lost nor consumed twice; an early record found at opening resolves the waitpoint in the same transaction.

  The invariants are database constraints (AG-11): a responder is never the waiter, an expired waitpoint cannot be resolved, a closed waitpoint does not change, and a waitpoint takes one response. Every state change writes a `waitpoint_event` record to the waiter's mailbox and an outbox event in the same transaction (AG-16, INV-35).

  Two timers, the total deadline and the waiter's heartbeat, are evaluated by one job per waitpoint, `Relay.Agents.WaitpointTimer`, scheduled for the nearest of them; an early wake-up finds nothing due and reschedules itself (AG-15). In `test` a timer is scheduled at its wall-clock time and a virtual clock step runs what fell due (TN-8).
  """

  alias Relay.Agents.WaitpointStore
  alias Relay.Agents.WaitpointTimer

  @tenant_open_cap 10_000
  @waiter_open_cap 1_000
  @due_batch 100

  @type kind :: :question | :review | :event
  @type waiter_kind :: :agent | :api_client

  # TN-54
  # T-91
  @doc "Default open waitpoint limits: per tenant and per waiter (ENGINEERING ASSUMPTION, T-91)."
  @spec default_caps() :: %{tenant: pos_integer(), waiter: pos_integer()}
  def default_caps, do: %{tenant: @tenant_open_cap, waiter: @waiter_open_cap}

  # C-72
  # AG-9
  # AG-13
  # AG-64
  # INV-12
  # T-24
  @doc """
  Opens a waitpoint and schedules its timer in one transaction. `attrs` carries `:id`, `:kind`, `:waiter_kind`, `:waiter_ref`, `:match_event_type`, `:correlation_key`, `:expires_at` and the optional fields of `relay_fn.waitpoint_open`.

  An early record waiting in the buffer resolves an `:event` waitpoint at once. For a question or review the caller decodes the early record: `:on_early` receives `%{waitpoint_id, record_id}` and returns the response attributes for `respond/3` (with `:source_record_id`), or `nil` to leave the record in the buffer.

  Options: `:tenant_open_cap`, `:waiter_open_cap`, `:on_early`.
  """
  @spec open(Relay.Scope.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def open(%Relay.Scope{} = scope, attrs, opts \\ []) do
    wp =
      Map.merge(attrs, %{
        tenant_open_cap: Keyword.get(opts, :tenant_open_cap, @tenant_open_cap),
        waiter_open_cap: Keyword.get(opts, :waiter_open_cap, @waiter_open_cap)
      })

    WaitpointStore.in_scope(scope, fn _status ->
      case WaitpointStore.open(wp) do
        {:opened, id, expires_at, early} ->
          :ok = schedule(scope, id)
          resolution = early(scope, wp, id, early, Keyword.get(opts, :on_early))
          %{result: :opened, waitpoint_id: id, expires_at: expires_at, early: resolution}

        {result, id, expires_at, _early} ->
          %{result: result, waitpoint_id: id, expires_at: expires_at, early: nil}
      end
    end)
  end

  defp early(_scope, _wp, _id, nil, _on_early), do: nil

  defp early(_scope, %{kind: :event}, id, record_id, _on_early),
    do: {:resolved_by_event, WaitpointStore.resolve_by_event(id, record_id, nil)}

  defp early(_scope, _wp, _id, _record_id, nil), do: :buffered

  defp early(_scope, _wp, id, record_id, on_early) when is_function(on_early, 1) do
    case on_early.(%{waitpoint_id: id, record_id: record_id}) do
      nil ->
        :buffered

      response ->
        WaitpointStore.respond(id, Map.put(response, :source_record_id, record_id))
    end
  end

  # AG-14
  # AG-13
  # C-73
  @doc """
  Offers an event: `:event_type`, `:correlation_key`, `:payload_digest`, optionally `:event_id`, the waiter (`:waiter_kind`, `:waiter_ref`) and the encrypted payload. Every matching event waitpoint is resolved in the same transaction; matching questions and reviews are returned for the caller to answer with `respond/3`. Without a match the event is buffered in the waiter's mailbox, or recorded as unmatched with its rule when no waiter is named.
  """
  @spec offer_event(Relay.Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def offer_event(%Relay.Scope{} = scope, event) do
    event = Map.put_new_lazy(event, :record_id, &Relay.Id.generate/0)

    WaitpointStore.in_scope(scope, fn _status ->
      case WaitpointStore.offer(event) do
        [{:buffered, nil, record_id}] ->
          %{result: :buffered, record_id: record_id, resolved: [], matched: []}

        [{:unmatched, nil, nil}] ->
          %{result: :unmatched, record_id: nil, resolved: [], matched: []}

        matches ->
          ids = for {:matched, id, _} <- matches, do: id
          resolve_matches(ids, Map.get(event, :event_id))
      end
    end)
  end

  defp resolve_matches(ids, event_id) do
    {resolved, matched} =
      Enum.reduce(ids, {[], []}, fn id, {resolved, matched} ->
        case WaitpointStore.get(id) do
          %{kind: "event"} ->
            result = WaitpointStore.resolve_by_event(id, Relay.Id.generate(), event_id)
            {[{id, result} | resolved], matched}

          _question_or_review ->
            {resolved, [id | matched]}
        end
      end)

    %{
      result: :matched,
      record_id: nil,
      resolved: Enum.reverse(resolved),
      matched: Enum.reverse(matched)
    }
  end

  # AG-11
  # C-72
  @doc """
  Answers a question or review once. `response` carries `:id`, `:responder_recipient_id`, `:responder_actor_ref`, `:session_actor_ref`, `:via`, `:evidence_level`, `:subject_digest`, `:value_ct`, `:value_key_id`, `:value_digest` and optionally `:evidence_ref` and `:source_record_id`. The value was validated against the response schema before this call; every refusal is recorded with its reason and returned as `:rejected_*`.
  """
  @spec respond(Relay.Scope.t(), Relay.Id.t(), map()) ::
          {:ok, {atom(), Relay.Id.t() | nil}} | {:error, term()}
  def respond(%Relay.Scope{} = scope, waitpoint_id, response),
    do:
      WaitpointStore.in_scope(scope, fn _status ->
        WaitpointStore.respond(waitpoint_id, response)
      end)

  # AG-10
  # AG-15
  @doc "Renews the waiter's heartbeat; a stalled waitpoint opens again."
  @spec heartbeat(Relay.Scope.t(), Relay.Id.t(), waiter_kind(), Relay.Id.t()) ::
          {:ok, {atom(), DateTime.t() | nil}} | {:error, term()}
  def heartbeat(%Relay.Scope{} = scope, waitpoint_id, waiter_kind, waiter_ref),
    do:
      WaitpointStore.in_scope(scope, fn _status ->
        WaitpointStore.heartbeat(waitpoint_id, waiter_kind, waiter_ref)
      end)

  # C-72
  @doc "Cancels an open waitpoint; an operator's cancellation is audited with the caller's record digest."
  @spec cancel(Relay.Scope.t(), Relay.Id.t(), String.t(), <<_::256>>, Relay.Actor.t()) ::
          {:ok, :cancelled | :already_terminal | :not_found} | {:error, term()}
  def cancel(%Relay.Scope{} = scope, waitpoint_id, reason, record_digest, actor),
    do:
      WaitpointStore.in_scope(scope, fn _status ->
        WaitpointStore.cancel(waitpoint_id, reason, record_digest, actor)
      end)

  @doc "Reads a waitpoint."
  @spec get(Relay.Scope.t(), Relay.Id.t()) :: {:ok, map() | nil} | {:error, term()}
  def get(%Relay.Scope{} = scope, waitpoint_id),
    do: WaitpointStore.in_scope(scope, fn _status -> WaitpointStore.get(waitpoint_id) end)

  # AG-46
  @doc "Lists waitpoints; `%{states: [:open, :stalled]}` lists the requests waiting for an answer."
  @spec list(Relay.Scope.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def list(%Relay.Scope{} = scope, filter \\ %{}),
    do: WaitpointStore.in_scope(scope, fn _status -> WaitpointStore.list(filter) end)

  # T-24
  # AG-15
  # WF-43
  @doc "Evaluates a waitpoint's timers in one transaction and schedules the next one when the waitpoint stays open."
  @spec fire(Relay.Scope.t(), Relay.Id.t()) :: {:ok, atom()} | {:error, term()}
  def fire(%Relay.Scope{} = scope, waitpoint_id) do
    WaitpointStore.in_scope(scope, fn _status ->
      case WaitpointStore.timer_fire(waitpoint_id) do
        {result, %DateTime{} = next_at} when result in [:stalled, :escalation_due, :not_due] ->
          :ok = insert_timer(scope, waitpoint_id, next_at)
          result

        {result, _next_at} ->
          result
      end
    end)
  end

  # T-24
  # TN-8
  @doc "Fires every waitpoint of a scope whose timer is due in business time; used by the missed-timer sweep and the virtual clock tick."
  @spec run_due(Relay.Scope.t()) :: :ok | {:error, term()}
  def run_due(%Relay.Scope{} = scope) do
    case WaitpointStore.in_scope(scope, fn _status -> WaitpointStore.due(@due_batch) end) do
      {:ok, due} ->
        Enum.each(due, fn {id, _due_at} -> fire(scope, id) end)
        if length(due) == @due_batch, do: run_due(scope), else: :ok

      {:error, _} = error ->
        error
    end
  end

  # T-24
  @doc "Fires the due waitpoints of every scope that has one."
  @spec sweep(pos_integer()) :: non_neg_integer()
  def sweep(limit \\ 100) do
    limit
    |> WaitpointStore.due_scopes()
    |> Enum.count(fn {tenant_id, environment} ->
      with {:ok, scope} <- Relay.Scope.new(tenant_id, environment),
           :ok <- run_due(scope) do
        true
      else
        _ -> false
      end
    end)
  end

  defp schedule(scope, waitpoint_id) do
    case WaitpointStore.get(waitpoint_id) do
      %{expires_at: expires_at, heartbeat_due_at: heartbeat} ->
        insert_timer(scope, waitpoint_id, earliest(expires_at, heartbeat))
    end
  end

  defp earliest(at, nil), do: at
  defp earliest(at, other), do: if(DateTime.compare(other, at) == :lt, do: other, else: at)

  defp insert_timer(scope, waitpoint_id, business_at) do
    args =
      scope
      |> Relay.Scope.to_job_args()
      |> Map.put("waitpoint_id", Relay.Id.to_string(waitpoint_id))

    job = WaitpointTimer.new(args, scheduled_at: Relay.Clock.wall_time(scope, business_at))

    case Oban.insert(job) do
      {:ok, _job} -> :ok
      {:error, reason} -> raise ArgumentError, "waitpoint timer not queued: #{inspect(reason)}"
    end
  end
end
