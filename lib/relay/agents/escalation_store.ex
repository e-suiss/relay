defmodule Relay.Agents.EscalationStore do
  @moduledoc """
  Data access for escalation policies and for the timed steps and invitations of a waitpoint (AG-17, AG-19, AG-63). Writes call the `relay_fn.escalation_policy_*` and `relay_fn.waitpoint_plan_*`, `relay_fn.waitpoint_steps_fire` and `relay_fn.waitpoint_invitation_settle` functions; reads select in the established scope. Every function but `in_scope/2` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  @type digest :: <<_::256>>
  @type plan :: %{
          policy_key: String.t() | nil,
          policy_version: pos_integer() | nil,
          tiers: [map()] | nil,
          surface_policy: [map()] | nil
        }

  @policy """
  p.id, p.key, p.state, p.version, p.archived_at, p.created_at, p.updated_at, v.description,
  v.tiers
  """

  @latest """
  relay.escalation_policies p
  JOIN relay.escalation_policy_versions v ON v.tenant_id = p.tenant_id
    AND v.environment = p.environment AND v.policy_id = p.id AND v.version = p.version
  """

  @put [
    :created,
    :versioned,
    :version_conflict,
    :precondition_required,
    :archived,
    :tier_limit,
    :responder_not_found,
    :tenant_inactive
  ]
  @check [
    :ok,
    :policy_not_found,
    :policy_archived,
    :responder_outside_set,
    :tier_limit,
    :surface_recipient_outside_set
  ]

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # AG-17
  # AG-53
  @doc "Writes a version of an escalation policy: the first one creates the policy, a later one needs the latest version as `expected_version`. `attrs` carries `:id`, `:version_id`, `:key`, `:description` and the `:tiers`."
  @spec put(map(), pos_integer() | nil, pos_integer(), digest(), Actor.t()) ::
          {atom(), Relay.Id.t() | nil, pos_integer() | nil}
  def put(attrs, expected_version, max_tiers, digest, %Actor{} = actor) do
    fields = [attrs.id, attrs.version_id, attrs.key, attrs.description, attrs.tiers]
    params = fields ++ [expected_version, max_tiers, digest] ++ Actor.params(actor)
    [row] = Repo.call!("relay_fn.escalation_policy_put", params)
    {Repo.code!(row["result"], @put), row["policy_id"], row["version"]}
  end

  # AG-17
  @doc "Archives an escalation policy; the row and its versions stay."
  @spec archive(String.t(), digest(), Actor.t()) ::
          {:archived | :already_archived | :not_found, pos_integer() | nil}
  def archive(key, digest, %Actor{} = actor) do
    params = [key, digest] ++ Actor.params(actor)
    [row] = Repo.call!("relay_fn.escalation_policy_archive", params)
    {Repo.code!(row["result"], [:archived, :already_archived, :not_found]), row["version"]}
  end

  # AG-17
  @doc "Reads an escalation policy with its latest version by key, or `nil`."
  @spec get(String.t()) :: map() | nil
  def get(key) do
    sql = "SELECT #{@policy} FROM #{@latest} WHERE p.key = $1"

    case maps(Repo.scoped_query!(sql, [key])) do
      [row] -> row
      [] -> nil
    end
  end

  # AG-17
  # API-56
  @doc "Lists escalation policies with their latest version, newest first, after or before a cursor position; `state` narrows the list."
  @spec list(String.t() | nil, map() | nil, pos_integer()) :: [map()]
  def list(state, cursor, limit) do
    {condition, order, params} = position(cursor, "p", [state])

    sql = """
    SELECT #{@policy}, p.created_at AS cursor_at FROM #{@latest}
    WHERE ($1::text IS NULL OR p.state = $1)#{condition}
    ORDER BY p.created_at #{order}, p.id #{order}
    LIMIT #{limit + 1}
    """

    ordered(maps(Repo.scoped_query!(sql, params)), order)
  end

  # AG-17
  # API-56
  @doc "Lists the versions of an escalation policy, newest first, after or before a cursor position; `nil` for an unknown key."
  @spec versions(String.t(), map() | nil, pos_integer()) :: [map()] | nil
  def versions(key, cursor, limit) do
    sql = "SELECT p.id FROM relay.escalation_policies p WHERE p.key = $1"

    case Repo.scoped_query!(sql, [key]).rows do
      [[policy_id]] -> versions_of(policy_id, key, cursor, limit)
      [] -> nil
    end
  end

  defp versions_of(policy_id, key, cursor, limit) do
    {condition, order, params} = position(cursor, "v", [policy_id, key])

    sql = """
    SELECT v.id, $2::text AS key, v.version, v.description, v.tiers, v.created_at,
      v.created_at AS cursor_at
    FROM relay.escalation_policy_versions v
    WHERE v.policy_id = $1#{condition}
    ORDER BY v.created_at #{order}, v.id #{order}
    LIMIT #{limit + 1}
    """

    ordered(maps(Repo.scoped_query!(sql, params)), order)
  end

  # AG-17
  @doc "The recipients among `ids` that are not deleted, as `{id, kind}`."
  @spec known([Relay.Id.t()]) :: [{Relay.Id.t(), String.t()}]
  def known(ids) do
    sql = """
    SELECT r.id, r.kind FROM relay.recipients r
    WHERE r.id = ANY ($1) AND r.state <> 'deleted'
    """

    for [id, kind] <- Repo.scoped_query!(sql, [ids]).rows, do: {id, kind}
  end

  # AG-12
  # AG-53
  @doc "Checks the escalation and surface plan of a waitpoint against its responders before it is opened; returns the result and the policy reference the waitpoint stores."
  @spec plan_check([Relay.Id.t()], plan(), pos_integer()) :: {atom(), String.t() | nil}
  def plan_check(responder_ids, plan, max_tiers) do
    params = [responder_ids | plan_params(plan, max_tiers)]
    [row] = Repo.call!("relay_fn.waitpoint_plan_check", params)
    {Repo.code!(row["result"], @check), row["policy_ref"]}
  end

  # AG-17
  # AG-63
  @doc "Pins the plan of an opened waitpoint: its tiers and surface steps become rows and the responders invited at creation get their invitations. Returns the result and the next step's time."
  @spec plan_pin(Relay.Id.t(), plan(), pos_integer()) :: {atom(), DateTime.t() | nil}
  def plan_pin(waitpoint_id, plan, max_tiers) do
    params = [waitpoint_id | plan_params(plan, max_tiers)]
    [row] = Repo.call!("relay_fn.waitpoint_plan_pin", params)
    codes = [:pinned, :already_pinned, :not_open, :not_found]
    {Repo.code!(row["result"], codes), row["next_at"]}
  end

  defp plan_params(plan, max_tiers),
    do: [plan.policy_key, plan.policy_version, plan.tiers, plan.surface_policy, max_tiers]

  # AG-19
  # WF-43
  @doc "Runs the steps of a waitpoint that are due; returns the result, how many ran and the next step's time."
  @spec steps_fire(Relay.Id.t()) :: {atom(), non_neg_integer(), DateTime.t() | nil}
  def steps_fire(waitpoint_id) do
    [row] = Repo.call!("relay_fn.waitpoint_steps_fire", [waitpoint_id])
    codes = [:fired, :not_due, :not_open, :not_found]
    {Repo.code!(row["result"], codes), row["fired"], row["next_at"]}
  end

  # AG-63
  # INV-35
  @doc "Settles an invitation as `:delivered` or `:unreachable`; an unreachable surface step is skipped and the next one runs at once."
  @spec settle(Relay.Id.t(), :delivered | :unreachable) :: {atom(), DateTime.t() | nil}
  def settle(invitation_id, outcome) do
    params = [invitation_id, Atom.to_string(outcome)]
    [row] = Repo.call!("relay_fn.waitpoint_invitation_settle", params)
    {Repo.code!(row["result"], [:settled, :already_settled, :not_found]), row["next_at"]}
  end

  # AG-19
  @doc "The steps of a waitpoint in track and order."
  @spec steps(Relay.Id.t()) :: [map()]
  def steps(waitpoint_id) do
    sql = """
    SELECT s.id, s.track, s.recipient_id, s.ordinal, s.level, s.after_ms, s.spec, s.state,
      s.due_at, s.remaining_ms, s.rule_id, s.settled_at
    FROM relay.waitpoint_steps s WHERE s.waitpoint_id = $1
    ORDER BY s.track, s.recipient_id, s.ordinal
    """

    maps(Repo.scoped_query!(sql, [waitpoint_id]))
  end

  # AG-63
  # INV-35
  @doc "The invitations of a waitpoint in one of `states`, oldest first."
  @spec invitations(Relay.Id.t(), [String.t()]) :: [map()]
  def invitations(waitpoint_id, states) do
    sql = """
    SELECT i.id, i.waitpoint_id, i.recipient_id, i.step_id, i.source, i.surfaces, i.inbox,
      i.state, i.rule_id, i.invited_at, i.settled_at
    FROM relay.waitpoint_invitations i
    WHERE i.waitpoint_id = $1 AND i.state = ANY ($2)
    ORDER BY i.invited_at, i.id
    """

    maps(Repo.scoped_query!(sql, [waitpoint_id, states]))
  end

  # AG-63
  @doc "The waitpoint of an invitation, or `nil`."
  @spec invitation_waitpoint(Relay.Id.t()) :: Relay.Id.t() | nil
  def invitation_waitpoint(invitation_id) do
    sql = "SELECT i.waitpoint_id FROM relay.waitpoint_invitations i WHERE i.id = $1"

    case Repo.scoped_query!(sql, [invitation_id]).rows do
      [[waitpoint_id]] -> waitpoint_id
      [] -> nil
    end
  end

  defp position(nil, _alias, params), do: {"", "DESC", params}

  defp position(%{direction: :after, sort_ts_us: ts, id: id}, table, params) do
    n = length(params)

    condition = " AND (#{table}.created_at, #{table}.id) < ($#{n + 1}, $#{n + 2})"
    {condition, "DESC", params ++ [from_us(ts), id]}
  end

  defp position(%{direction: :before, sort_ts_us: ts, id: id}, table, params) do
    n = length(params)

    condition = " AND (#{table}.created_at, #{table}.id) > ($#{n + 1}, $#{n + 2})"
    {condition, "ASC", params ++ [from_us(ts), id]}
  end

  defp ordered(rows, "ASC"), do: Enum.reverse(rows)
  defp ordered(rows, _desc), do: rows

  defp from_us(us), do: DateTime.from_unix!(us, :microsecond)

  defp maps(%Postgrex.Result{columns: columns, rows: rows}),
    do: Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
end
