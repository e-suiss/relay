defmodule Relay.Agents.Ceiling.Store do
  @moduledoc """
  Data access of the agent ceiling (AG-48, AG-49, AG-50): the record of every agent notification that reached the ceiling check (`relay.agent_ceiling_holds`, passed or held), the ceiling events, the owner's decisions and the run state of an agent. Writes go through `relay_fn.agent_ceiling_pass`, `relay_fn.agent_ceiling_hold`, `relay_fn.agent_ceiling_decide`, `relay_fn.agent_ceiling_apply` and `relay_fn.agent_resume`; a hold pauses its delivery, opens the ceiling event and appends `agent.ceiling_exceeded` in one transaction, and nothing is ever deleted. Every function except `in_scope/2` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  @type id :: Relay.Id.t()
  @type cursor :: map() | nil

  @hour_key "agents.ceiling.per_hour"
  @day_key "agents.ceiling.per_day"
  @attributed ~w(attributed exists not_found)a
  @passed ~w(passed already_passed held released cancelled expired not_found)a
  @held ~w(held passed released cancelled expired not_found)a
  @decided ~w(decided exists conflict step_up_required agent_not_found ceiling_event_not_found)a
  @resumed ~w(resumed unchanged agent_not_found)a
  @outcomes ~w(resumed cancelled expired none)a

  @status """
  SELECT h.state AS hold_state, h.agent_ref,
    EXISTS (SELECT 1 FROM relay.agent_run_states s
      WHERE s.agent_ref = h.agent_ref AND s.state = 'stopped') AS stopped
  FROM relay.agent_ceiling_holds h WHERE h.notification_id = $1
  """

  @run_state """
  SELECT c.id AS agent_ref, c.created_at, s.state, s.decision_ref, s.changed_at
  FROM relay.agents c
  LEFT JOIN relay.agent_run_states s ON s.tenant_id = c.tenant_id
    AND s.environment = c.environment AND s.agent_ref = c.id
  WHERE c.id = $1
  """

  @decision """
  SELECT d.id, d.agent_ref, d.ceiling_event_id, d.decision, d.decision_ref, d.note,
    d.applied_count, d.decided_at
  FROM relay.agent_ceiling_decisions d WHERE d.id = $1
  """

  @holds "h.notification_id AS id, h.notification_id, h.agent_ref, h.state, h.rule_id, h.ceiling_event_id, h.decision_id, h.expires_at, h.held_at, h.decided_at, h.held_at AS cursor_at"

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # AG-48
  # AG-70
  @doc "What the ceiling check reads for a notification attributed to an agent: the agent, the state of the notification's record, whether the agent is stopped and the tenant's own ceiling values; `nil` for a notification no agent is named for."
  @spec status(id()) :: map() | nil
  def status(notification_id) do
    case one(@status, [notification_id]) do
      nil -> nil
      row -> Map.merge(limits(), status_of(row))
    end
  end

  defp status_of(row),
    do: %{agent_ref: row["agent_ref"], hold_state: row["hold_state"], stopped: row["stopped"]}

  defp limits do
    settings =
      for setting <- Repo.call!("relay_fn.setting_resolve", [nil, [@hour_key, @day_key]]),
          into: %{},
          do: {setting["key"], setting["value"]}

    %{per_hour: settings[@hour_key], per_day: settings[@day_key]}
  end

  # AG-48
  # E-56
  @doc "Attributes a notification of sender type `agent` to the agent whose credential sent it; an attributed notification keeps its agent."
  @spec attribute(id(), id()) :: :attributed | :exists | :not_found
  def attribute(notification_id, agent_ref) do
    [row] = Repo.call!("relay_fn.agent_ceiling_attribute", [notification_id, agent_ref])
    Repo.code!(row["agent_ceiling_attribute"], @attributed)
  end

  # AG-48
  @doc "Records that a notification of an agent passed the ceiling; a notification that already has a record returns its state."
  @spec pass(id(), id()) ::
          :passed | :already_passed | :held | :released | :cancelled | :expired | :not_found
  def pass(notification_id, agent_ref) do
    [row] = Repo.call!("relay_fn.agent_ceiling_pass", [notification_id, agent_ref])
    Repo.code!(row["agent_ceiling_pass"], @passed)
  end

  # AG-49
  # INV-3
  @doc "Holds a delivery of an agent's notification under `rule_id`: the delivery is paused and its notification recorded as held; the first hold of an agent opens the ceiling event `event_id` and appends `agent.ceiling_exceeded`. Returns the result, the ceiling event and its held count."
  @spec hold(id(), id(), id(), String.t()) :: {atom(), id() | nil, non_neg_integer() | nil}
  def hold(event_id, delivery_id, agent_ref, rule_id) do
    params = [event_id, delivery_id, agent_ref, rule_id]
    [row] = Repo.call!("relay_fn.agent_ceiling_hold", params)
    {Repo.code!(row["result"], @held), row["ceiling_event_id"], row["held_count"]}
  end

  # AG-49
  # TN-21
  # TN-47
  @doc "Records the owner's decision on a ceiling event with its audit record; `decision` carries `:id`, `:agent_ref`, `:ceiling_event_id`, `:decision`, `:decision_ref` and `:note`. Returns the result, the decision's identifier and the number of held notifications it applies to."
  @spec decide(map(), binary(), Actor.t()) :: {atom(), id() | nil, non_neg_integer() | nil}
  def decide(decision, digest, %Actor{} = actor) do
    params =
      [
        decision.id,
        decision.agent_ref,
        decision.ceiling_event_id,
        decision.decision,
        decision.decision_ref,
        decision.note,
        digest
      ] ++ Actor.params(actor)

    [row] = Repo.call!("relay_fn.agent_ceiling_decide", params)
    {Repo.code!(row["result"], @decided), row["decision_id"], row["applied_count"]}
  end

  # AG-49
  @doc "Applies a decision to at most `limit` of the notifications it covers and returns, for each of their paused deliveries, the outcome (`:resumed`, `:cancelled`, `:expired`) and the delivery; a notification without a paused delivery is `{:none, nil}`. An empty list means nothing is left to apply."
  @spec apply_batch(id(), pos_integer()) :: [{atom(), id() | nil}]
  def apply_batch(decision_id, limit) do
    for row <- Repo.call!("relay_fn.agent_ceiling_apply", [decision_id, limit]),
        do: {Repo.code!(row["outcome"], @outcomes), row["delivery_id"]}
  end

  # AG-49
  # TN-47
  @doc "Lifts a stop decision on an agent with its audit record; returns the result and the time of the agent's last state change."
  @spec resume(id(), String.t(), binary(), Actor.t()) :: {atom(), DateTime.t() | nil}
  def resume(agent_ref, decision_ref, digest, %Actor{} = actor) do
    params = [agent_ref, decision_ref, digest] ++ Actor.params(actor)
    [row] = Repo.call!("relay_fn.agent_resume", params)
    {Repo.code!(row["result"], @resumed), row["changed_at"]}
  end

  # AG-49
  @doc "The run state of an agent, or `nil` when the scope has no such agent: `state` and `decision_ref` are `nil` for an agent no decision ever stopped."
  @spec run_state(id()) :: map() | nil
  def run_state(agent_ref), do: one(@run_state, [agent_ref])

  # AG-49
  @doc "Reads a decision, or `nil`."
  @spec decision(id()) :: map() | nil
  def decision(id), do: one(@decision, [id])

  # AG-49
  # INV-3
  # API-56
  @doc "A page of the notifications of an agent that were held, newest first, optionally of one state; at most `limit + 1` rows, each with its `cursor_at`."
  @spec holds(id(), String.t() | nil, cursor(), pos_integer()) :: [map()]
  def holds(agent_ref, state, cursor, limit) do
    {condition, order, params} = window(cursor, [agent_ref, state])

    sql = """
    SELECT #{@holds} FROM relay.agent_ceiling_holds h
    WHERE h.agent_ref = $1 AND h.held_at IS NOT NULL
      AND ($2::text IS NULL OR h.state = $2)#{condition}
    ORDER BY h.held_at #{order}, h.notification_id #{order}
    LIMIT #{limit + 1}
    """

    rows = all(sql, params)
    if order == "ASC", do: Enum.reverse(rows), else: rows
  end

  defp window(nil, params), do: {"", "DESC", params}

  defp window(%{direction: :after, sort_ts_us: ts, id: id}, params),
    do: {" AND (h.held_at, h.notification_id) < ($3, $4)", "DESC", params ++ [from_us(ts), id]}

  defp window(%{direction: :before, sort_ts_us: ts, id: id}, params),
    do: {" AND (h.held_at, h.notification_id) > ($3, $4)", "ASC", params ++ [from_us(ts), id]}

  defp from_us(us), do: DateTime.from_unix!(us, :microsecond)

  defp one(sql, params) do
    case all(sql, params) do
      [row] -> row
      [] -> nil
    end
  end

  defp all(sql, params) do
    %{rows: rows, columns: columns} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
