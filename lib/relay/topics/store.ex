defmodule Relay.Topics.Store do
  @moduledoc """
  Data access of topics, their subscriptions and the frozen audiences of sends through the `relay_fn.topic_*` and `relay_fn.audience_record` functions (WF-51, WF-52, WF-53). A topic is unique per tenant environment by its key and has at most one parent, which itself has none; a subscription binds one subscriber to one topic and is kept as `removed` when it ends. Rows are never deleted. Every function runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  @topic_columns """
  t.id, t.key, t.state, t.version, t.archived_at, t.created_at, t.updated_at,
    p.key AS parent_key
  """
  @topics "relay.topics t LEFT JOIN relay.topics p ON p.tenant_id = t.tenant_id AND p.environment = t.environment AND p.id = t.parent_id"
  @subscription_columns "s.id, s.recipient_id, s.state, s.removed_at, s.created_at, t.key AS topic_key"
  @subscriptions "relay.topic_subscriptions s JOIN relay.topics t ON t.tenant_id = s.tenant_id AND t.environment = s.environment AND t.id = s.topic_id"
  @created ~w(created key_conflict parent_not_found too_deep parent_archived tenant_inactive)a
  @archived ~w(archived already_archived not_found)a
  @subscribed ~w(subscribed exists recipient_not_found)a
  @refused ~w(topic_not_found topic_archived tenant_inactive)a
  @unsubscribed ~w(unsubscribed already_unsubscribed not_subscribed recipient_not_found)a

  @type id :: Relay.Id.t()

  # WF-51
  @doc "Creates a topic under an optional parent key; returns the result, the topic's identifier and its version."
  @spec create(String.t(), String.t() | nil, binary(), Actor.t()) ::
          {atom(), id() | nil, pos_integer() | nil}
  def create(key, parent_key, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.topic_create",
        [Relay.Id.generate(), key, parent_key, digest] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], @created), row["topic_id"], row["version"]}
  end

  # WF-51
  @doc "Archives a topic; returns the result and its version."
  @spec archive(String.t(), binary(), Actor.t()) :: {atom(), pos_integer() | nil}
  def archive(key, digest, %Actor{} = actor) do
    [row] = Repo.call!("relay_fn.topic_archive", [key, digest] ++ Actor.params(actor))
    {Repo.code!(row["result"], @archived), row["version"]}
  end

  # WF-51
  @doc "Subscribes the subscribers of blind indexes to a topic; returns one `{ordinal, result, recipient_id, subscription_id}` per index, or the topic's refusal."
  @spec subscribe(String.t(), [binary(), ...], binary(), Actor.t()) ::
          {:ok, [{pos_integer(), atom(), id() | nil, id() | nil}]}
          | {:error, :topic_not_found | :topic_archived | :tenant_inactive}
  def subscribe(key, bidxs, digest, %Actor{} = actor) do
    ids = Enum.map(bidxs, fn _bidx -> Relay.Id.generate() end)
    params = [key, bidxs, ids, digest] ++ Actor.params(actor)

    case Repo.call!("relay_fn.topic_subscribe", params) do
      [%{"ordinal" => 0, "result" => result}] -> {:error, Repo.code!(result, @refused)}
      rows -> {:ok, Enum.map(rows, &subscribed/1)}
    end
  end

  defp subscribed(row) do
    result = Repo.code!(row["result"], @subscribed)
    {row["ordinal"], result, row["recipient_id"], row["subscription_id"]}
  end

  # WF-51
  @doc "Ends the subscriptions of the subscribers of blind indexes to a topic, kept as `removed`; returns one `{ordinal, result, recipient_id, subscription_id}` per index, or `:topic_not_found`."
  @spec unsubscribe(String.t(), [binary(), ...], binary(), Actor.t()) ::
          {:ok, [{pos_integer(), atom(), id() | nil, id() | nil}]} | {:error, :topic_not_found}
  def unsubscribe(key, bidxs, digest, %Actor{} = actor) do
    params = [key, bidxs, digest] ++ Actor.params(actor)

    case Repo.call!("relay_fn.topic_unsubscribe", params) do
      [%{"ordinal" => 0, "result" => "topic_not_found"}] -> {:error, :topic_not_found}
      rows -> {:ok, Enum.map(rows, &unsubscribed/1)}
    end
  end

  defp unsubscribed(row) do
    result = Repo.code!(row["result"], @unsubscribed)
    {row["ordinal"], result, row["recipient_id"], row["subscription_id"]}
  end

  # WF-52
  # WF-53
  # F-5
  @doc "Records the frozen audience of a source: its topics and one row per recipient with the topic it was reached through and whether it was also named directly."
  @spec record(id(), String.t(), id(), [id(), ...], [map()]) :: :recorded | :exists
  def record(id, source_kind, source_id, topic_ids, members) do
    [row] =
      Repo.call!("relay_fn.audience_record", [
        id,
        source_kind,
        source_id,
        topic_ids,
        Enum.map(members, & &1.recipient_id),
        Enum.map(members, & &1.topic_id),
        Enum.map(members, & &1.also_direct)
      ])

    Repo.code!(row["result"], [:recorded, :exists])
  end

  # WF-51
  @doc "Reads a topic by key with its parent's key, or `nil`."
  @spec get(String.t()) :: map() | nil
  def get(key), do: one("SELECT #{@topic_columns} FROM #{@topics} WHERE t.key = $1", [key])

  # WF-51
  # API-56
  @doc "A page of topics, newest first, at most `limit + 1` rows."
  @spec topics(map() | nil, pos_integer()) :: [map()]
  def topics(cursor, limit), do: page(@topics, @topic_columns, "t", "TRUE", [], cursor, limit)

  # WF-51
  @doc "The subscriptions of identifiers, with their topic's key."
  @spec subscriptions_by_id([id()]) :: [map()]
  def subscriptions_by_id(ids),
    do: all("SELECT #{@subscription_columns} FROM #{@subscriptions} WHERE s.id = ANY ($1)", [ids])

  # WF-51
  # API-56
  @doc "A page of the active subscriptions of a topic, newest first."
  @spec topic_subscriptions(id(), map() | nil, pos_integer()) :: [map()]
  def topic_subscriptions(topic_id, cursor, limit) do
    where = "s.topic_id = $1 AND s.state = 'active'"
    page(@subscriptions, @subscription_columns, "s", where, [topic_id], cursor, limit)
  end

  # WF-51
  # API-56
  @doc "A page of the active subscriptions of a subscriber, newest first."
  @spec recipient_subscriptions(id(), map() | nil, pos_integer()) :: [map()]
  def recipient_subscriptions(recipient_id, cursor, limit) do
    where = "s.recipient_id = $1 AND s.state = 'active'"
    page(@subscriptions, @subscription_columns, "s", where, [recipient_id], cursor, limit)
  end

  # WF-51
  # WF-53
  @doc "The topics of keys with the identifier and state of their parent."
  @spec resolve([String.t()]) :: [map()]
  def resolve(keys) do
    all(
      """
      SELECT t.id, t.key, t.state, t.parent_id, p.state AS parent_state FROM #{@topics}
      WHERE t.key = ANY ($1)
      """,
      [keys]
    )
  end

  # WF-52
  # L-31
  @doc "The active subscribers of the topics `paths`, each once with the earliest topic of `paths` it is subscribed to, in identifier order, at most `limit`."
  @spec members([id(), ...], pos_integer()) :: [{id(), id()}]
  def members(paths, limit) do
    """
    SELECT DISTINCT ON (s.recipient_id) s.recipient_id, s.topic_id
    FROM relay.topic_subscriptions s
    JOIN relay.recipients r ON r.tenant_id = s.tenant_id AND r.environment = s.environment
      AND r.id = s.recipient_id
    WHERE s.topic_id = ANY ($1) AND s.state = 'active' AND r.kind = 'subscriber'
      AND r.state = 'active'
    ORDER BY s.recipient_id, array_position($1, s.topic_id)
    LIMIT $2
    """
    |> all([paths, limit])
    |> Enum.map(&{&1["recipient_id"], &1["topic_id"]})
  end

  # WF-53
  @doc "How many active subscribers each of the topics `paths` has."
  @spec reach([id(), ...]) :: %{id() => non_neg_integer()}
  def reach(paths) do
    """
    SELECT s.topic_id, count(*) AS subscribers
    FROM relay.topic_subscriptions s
    JOIN relay.recipients r ON r.tenant_id = s.tenant_id AND r.environment = s.environment
      AND r.id = s.recipient_id
    WHERE s.topic_id = ANY ($1) AND s.state = 'active' AND r.kind = 'subscriber'
      AND r.state = 'active'
    GROUP BY s.topic_id
    """
    |> all([paths])
    |> Map.new(&{&1["topic_id"], &1["subscribers"]})
  end

  defp page(from, columns, alias_, where, params, cursor, limit) do
    {condition, order, params} =
      case cursor do
        nil ->
          {"", "DESC", params}

        %{direction: :after, sort_ts_us: ts, id: id} ->
          n = length(params)

          {" AND (#{alias_}.created_at, #{alias_}.id) < ($#{n + 1}, $#{n + 2})", "DESC",
           params ++ [from_us(ts), id]}

        %{direction: :before, sort_ts_us: ts, id: id} ->
          n = length(params)

          {" AND (#{alias_}.created_at, #{alias_}.id) > ($#{n + 1}, $#{n + 2})", "ASC",
           params ++ [from_us(ts), id]}
      end

    sql = """
    SELECT #{columns}, #{alias_}.created_at AS cursor_at FROM #{from}
    WHERE #{where}#{condition}
    ORDER BY #{alias_}.created_at #{order}, #{alias_}.id #{order}
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
