defmodule Relay.Agents.WaitpointStore do
  @moduledoc """
  Data access for waitpoints through the `relay_fn.waitpoint_*` functions inside `Relay.Repo.in_scope/3`, and the cross-tenant discovery of scopes with due timers through `relay_ops.waitpoint_due_scopes`.
  """

  alias Relay.Actor
  alias Relay.Repo

  @open [
    :opened,
    :exists,
    :active_exists,
    :expires_invalid,
    :condition_unsupported,
    :limit_exceeded,
    :waiter_not_found,
    :responder_not_found,
    :responder_is_waiter,
    :tenant_inactive
  ]
  @respond [
    :resolved,
    :rejected_expired,
    :rejected_closed,
    :rejected_not_responder,
    :rejected_is_waiter,
    :rejected_digest_mismatch,
    :rejected_session_mismatch,
    :not_found
  ]
  @heartbeat [:renewed, :reopened, :no_heartbeat, :already_terminal, :not_waiter, :not_found]
  @timer [:expired, :stalled, :escalation_due, :not_due, :already_terminal, :not_found]

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # AG-9
  # AG-13
  # INV-12
  @doc "Opens a waitpoint; returns the result, the waitpoint, its stored deadline and an early record waiting in the buffer."
  @spec open(map()) ::
          {atom(), Relay.Id.t() | nil, DateTime.t() | nil, Relay.Id.t() | nil}
  def open(wp) do
    [row] =
      Repo.call!("relay_fn.waitpoint_open", [
        wp.id,
        Atom.to_string(wp.kind),
        Atom.to_string(wp.waiter_kind),
        wp.waiter_ref,
        Map.get(wp, :mailbox_id),
        wp.match_event_type,
        wp.correlation_key,
        Map.get(wp, :condition),
        Map.get(wp, :response_schema),
        Map.get(wp, :responder_ids, []),
        Map.get(wp, :subject_digest),
        Map.get(wp, :content_ct),
        Map.get(wp, :claim_text_ct),
        Map.get(wp, :default_response_ct),
        Map.get(wp, :field_key_id),
        Map.get(wp, :expires_at),
        Map.get(wp, :heartbeat_interval_ms),
        Map.get(wp, :escalation_policy_ref),
        Map.get(wp, :surface_policy),
        Map.get(wp, :deliver_to_topics, []),
        Map.get(wp, :tags, []),
        wp.tenant_open_cap,
        wp.waiter_open_cap,
        Map.get(wp, :traceparent)
      ])

    {Repo.code!(row["result"], @open), row["waitpoint_id"], row["expires_at"],
     row["early_record_id"]}
  end

  # AG-14
  # AG-13
  @doc "Offers an event to the waitpoints that wait for its type and correlation key."
  @spec offer(map()) :: [{:matched | :buffered | :unmatched, Relay.Id.t() | nil, Relay.Id.t() | nil}]
  def offer(event) do
    for row <-
          Repo.call!("relay_fn.waitpoint_event_offer", [
            Map.get(event, :event_id),
            event.event_type,
            event.correlation_key,
            event |> Map.get(:waiter_kind) |> kind_text(),
            Map.get(event, :waiter_ref),
            Map.get(event, :record_id),
            Map.get(event, :payload_ct),
            Map.get(event, :payload_subject_key_id),
            Map.get(event, :payload_tenant_key_id),
            event.payload_digest
          ]),
        do:
          {Repo.code!(row["result"], [:matched, :buffered, :unmatched]), row["waitpoint_id"],
           row["record_id"]}
  end

  # C-72
  @doc "Resolves an event waitpoint with a mailbox record."
  @spec resolve_by_event(Relay.Id.t(), Relay.Id.t(), Relay.Id.t() | nil) ::
          :resolved | :expired | :already_terminal | :not_found
  def resolve_by_event(waitpoint_id, record_id, source_event_id) do
    [row] =
      Repo.call!("relay_fn.waitpoint_resolve_by_event", [
        waitpoint_id,
        record_id,
        source_event_id
      ])

    Repo.code!(row["waitpoint_resolve_by_event"], [
      :resolved,
      :expired,
      :already_terminal,
      :not_found
    ])
  end

  # AG-11
  # C-72
  @doc "Records a response; every refusal is recorded with its reason."
  @spec respond(Relay.Id.t(), map()) :: {atom(), Relay.Id.t() | nil}
  def respond(waitpoint_id, response) do
    [row] =
      Repo.call!("relay_fn.waitpoint_respond", [
        waitpoint_id,
        response.id,
        response.responder_recipient_id,
        response.responder_actor_ref,
        response.session_actor_ref,
        response.via,
        Atom.to_string(response.evidence_level),
        Map.get(response, :evidence_ref),
        response.subject_digest,
        response.value_ct,
        response.value_key_id,
        response.value_digest,
        Map.get(response, :source_record_id)
      ])

    {Repo.code!(row["result"], @respond), row["response_id"]}
  end

  # AG-10
  # AG-15
  @doc "Renews the waiter's heartbeat."
  @spec heartbeat(Relay.Id.t(), atom(), Relay.Id.t()) :: {atom(), DateTime.t() | nil}
  def heartbeat(waitpoint_id, waiter_kind, waiter_ref) do
    [row] =
      Repo.call!("relay_fn.waitpoint_heartbeat", [
        waitpoint_id,
        kind_text(waiter_kind),
        waiter_ref
      ])

    {Repo.code!(row["result"], @heartbeat), row["heartbeat_due_at"]}
  end

  # T-24
  # AG-15
  @doc "Evaluates the timers of a waitpoint and returns what happened and the next business time."
  @spec timer_fire(Relay.Id.t()) :: {atom(), DateTime.t() | nil}
  def timer_fire(waitpoint_id) do
    [row] = Repo.call!("relay_fn.waitpoint_timer_fire", [waitpoint_id])
    {Repo.code!(row["result"], @timer), row["next_at"]}
  end

  # C-72
  @doc "Cancels an open waitpoint."
  @spec cancel(Relay.Id.t(), String.t(), <<_::256>>, Actor.t()) ::
          :cancelled | :already_terminal | :not_found
  def cancel(waitpoint_id, reason, digest, %Actor{} = actor) do
    [row] =
      Repo.call!("relay_fn.waitpoint_cancel", [waitpoint_id, reason, digest | Actor.params(actor)])

    Repo.code!(row["waitpoint_cancel"], [:cancelled, :already_terminal, :not_found])
  end

  @doc "Reads a waitpoint."
  @spec get(Relay.Id.t()) :: map() | nil
  def get(waitpoint_id) do
    case Repo.call!("relay_fn.waitpoint_get", [waitpoint_id]) do
      [row] -> waitpoint(row)
      [] -> nil
    end
  end

  # AG-46
  @doc "Lists waitpoints by state, waiter and tags, after a waitpoint identifier."
  @spec list(map()) :: [map()]
  def list(filter) do
    for row <-
          Repo.call!("relay_fn.waitpoint_list", [
            filter |> Map.get(:states) |> states(),
            filter |> Map.get(:waiter_kind) |> kind_text(),
            Map.get(filter, :waiter_ref),
            Map.get(filter, :tags),
            Map.get(filter, :after_id),
            Map.get(filter, :limit, 100)
          ]),
        do: waitpoint(row)
  end

  # T-24
  @doc "Lists the waitpoints of the established scope whose next timer is due in business time."
  @spec due(pos_integer()) :: [{Relay.Id.t(), DateTime.t()}]
  def due(limit) do
    for row <- Repo.call!("relay_fn.waitpoint_due", [limit]),
        do: {row["waitpoint_id"], row["due_at"]}
  end

  # T-24
  # TN-13 (4)
  @doc "Lists the scopes that have a due waitpoint timer, through the discovery escape hatch; scopes only, no content."
  @spec due_scopes(pos_integer()) :: [{Relay.Id.t(), String.t()}]
  def due_scopes(limit) when is_integer(limit) and limit > 0 do
    for row <-
          Repo.call_unscoped!(:waitpoint_due_discovery, "relay_ops.waitpoint_due_scopes", [limit]),
        do: {row["tenant_id"], row["environment"]}
  end

  defp kind_text(nil), do: nil
  defp kind_text(kind) when is_atom(kind), do: Atom.to_string(kind)

  defp states(nil), do: nil
  defp states(states), do: Enum.map(states, &Atom.to_string/1)

  defp waitpoint(row) do
    %{
      id: row["id"],
      kind: row["kind"],
      waiter_kind: row["waiter_kind"],
      waiter_ref: row["waiter_ref"],
      mailbox_id: row["waiter_mailbox_id"],
      match_event_type: row["match_event_type"],
      correlation_key: row["correlation_key"],
      state: row["state"],
      opened_at: row["opened_at"],
      expires_at: row["expires_at"],
      heartbeat_due_at: row["heartbeat_due_at"],
      next_escalation_at: row["next_escalation_at"],
      resolved_at: row["resolved_at"],
      resolution_response_id: row["resolution_response_id"],
      resolved_by_record_id: row["resolved_by_record_id"],
      tags: row["tags"],
      version: row["version"]
    }
  end
end
