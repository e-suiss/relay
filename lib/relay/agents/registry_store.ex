defmodule Relay.Agents.RegistryStore do
  @moduledoc """
  Data access of the agent recipient records (`relay.agents`, C-21, E-28) through the `relay_fn.agent_*` functions. An agent is a recipient of kind `agent` whose external identifier is its Access Party reference; the agent row adds its name, owner, delivery endpoints and state. Rows are never deleted. Every function except `in_scope/2` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  @columns """
  a.id, a.name, a.owner_ref, a.webhook_endpoint_id, a.a2a_push_endpoint_id, a.realtime,
    a.state, a.suspended_at, a.deleted_at, a.version, a.created_at, a.updated_at,
    r.external_id_ct,
    (SELECT m.id FROM relay.mailboxes m
      WHERE m.tenant_id = a.tenant_id AND m.environment = a.environment
        AND m.owner_kind = 'agent' AND m.owner_ref = a.id) AS mailbox_id,
    (SELECT m.state FROM relay.mailboxes m
      WHERE m.tenant_id = a.tenant_id AND m.environment = a.environment
        AND m.owner_kind = 'agent' AND m.owner_ref = a.id) AS mailbox_state,
    ARRAY(SELECT t.key FROM relay.topic_subscriptions s
      JOIN relay.topics t ON t.tenant_id = s.tenant_id AND t.environment = s.environment
        AND t.id = s.topic_id
      WHERE s.tenant_id = a.tenant_id AND s.environment = a.environment
        AND s.recipient_id = a.id AND s.state = 'active'
      ORDER BY t.key) AS topics
  """
  @agents "relay.agents a JOIN relay.recipients r ON r.tenant_id = a.tenant_id AND r.environment = a.environment AND r.id = a.id"
  @created ~w(created party_conflict endpoint_not_found topic_not_found topic_archived
              tenant_inactive)a
  @updated ~w(updated version_conflict not_found deleted endpoint_not_found topic_not_found
              topic_archived)a
  @state ~w(suspended reactivated deleted unchanged not_found)a

  @type id :: Relay.Id.t()
  @type bidxs :: [binary()] | nil

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # C-21
  # E-28
  # E-29
  @doc "Creates an agent recipient with its record, its one mailbox and its topic subscriptions; returns the result, the agent and its mailbox."
  @spec create(map(), binary(), Actor.t()) :: {atom(), id() | nil, id() | nil}
  def create(plan, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.agent_create",
        [
          plan.id,
          plan.party_bidx,
          plan.bidx_key_id,
          plan.party_ct,
          plan.profile_dek_id,
          plan.wrapped_dek,
          plan.wrapping_key_id,
          plan.name,
          plan.owner_ref,
          plan.webhook_endpoint_id,
          plan.a2a_push_endpoint_id,
          plan.realtime,
          plan.topics,
          digest
        ] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], @created), row["agent_id"], row["mailbox_id"]}
  end

  # C-21
  # E-28
  @doc "Changes the named `fields` of an agent under an optional expected version; returns the result and the agent's version."
  @spec update(id(), map(), pos_integer() | nil, binary(), Actor.t()) ::
          {atom(), pos_integer() | nil}
  def update(id, change, expected_version, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.agent_update",
        [
          id,
          change.fields,
          change.name,
          change.owner_ref,
          change.webhook_endpoint_id,
          change.a2a_push_endpoint_id,
          change.realtime,
          change.topics,
          expected_version,
          digest
        ] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], @updated), row["version"]}
  end

  # AG-5
  # E-29
  # AG-23
  # INV-47
  @doc "Moves an agent, named by its identifier or by the blind indexes of its Access Party reference, to `state` (`active`, `suspended` or `deleted`) and its mailbox with it: a suspended or deleted agent's mailbox is suspended, never deleted. Returns the result, the agent and its version."
  @spec set_state(id() | nil, bidxs(), String.t(), String.t() | nil, binary(), Actor.t()) ::
          {atom(), id() | nil, pos_integer() | nil}
  def set_state(id, party_bidxs, state, access_event_ref, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.agent_set_state",
        [id, party_bidxs, state, access_event_ref, digest] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], @state), row["agent_id"], row["version"]}
  end

  # C-21
  @doc "Reads an agent with its mailbox and the keys of its topics, or `nil`."
  @spec get(id()) :: map() | nil
  def get(id), do: one("SELECT #{@columns} FROM #{@agents} WHERE a.id = $1", [id])

  # E-29
  # AG-5
  @doc "The identifier and state of the agent whose Access Party reference has one of these blind indexes, or `nil`."
  @spec by_party([binary()]) :: %{id: id(), state: String.t()} | nil
  def by_party(bidxs) do
    sql = """
    SELECT a.id, a.state FROM #{@agents}
    WHERE r.kind = 'agent'
      AND (r.external_id_bidx = ANY ($1) OR r.external_id_bidx_next = ANY ($1))
    """

    case one(sql, [bidxs]) do
      %{"id" => id, "state" => state} -> %{id: id, state: state}
      nil -> nil
    end
  end

  # AG-5
  @doc "The state of an agent, or `nil`."
  @spec state(id()) :: String.t() | nil
  def state(id) do
    case one("SELECT a.state FROM relay.agents a WHERE a.id = $1", [id]) do
      %{"state" => state} -> state
      nil -> nil
    end
  end

  # C-21
  # API-56
  @doc "A page of agents, newest first, deleted ones included; at most `limit + 1` rows."
  @spec list(map() | nil, pos_integer()) :: [map()]
  def list(cursor, limit) do
    {condition, order, params} =
      case cursor do
        nil ->
          {"", "DESC", []}

        %{direction: :after, sort_ts_us: ts, id: id} ->
          {"WHERE (a.created_at, a.id) < ($1, $2)", "DESC", [from_us(ts), id]}

        %{direction: :before, sort_ts_us: ts, id: id} ->
          {"WHERE (a.created_at, a.id) > ($1, $2)", "ASC", [from_us(ts), id]}
      end

    sql = """
    SELECT #{@columns}, a.created_at AS cursor_at FROM #{@agents}
    #{condition}
    ORDER BY a.created_at #{order}, a.id #{order}
    LIMIT #{limit + 1}
    """

    rows = all(sql, params)
    if order == "ASC", do: Enum.reverse(rows), else: rows
  end

  defp from_us(us), do: DateTime.from_unix!(us, :microsecond)

  defp one(sql, params) do
    case all(sql, params) do
      [row] -> row
      [] -> nil
    end
  end

  defp all(sql, params) do
    %Postgrex.Result{columns: columns, rows: rows} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
