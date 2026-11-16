defmodule Relay.Workflow.RouteStore do
  @moduledoc """
  Data access of named routes (WF-13, WF-14). Writes call the `relay_fn.route_*` functions; reads select the routes and the default route of a category in the established scope. Every function runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  @type digest :: <<_::256>>

  @columns """
  r.id, r.key, r.name, r.tree, r.state, r.archived_at, r.version, r.created_at, r.updated_at
  """

  # WF-13
  @doc "Creates a named route."
  @spec create(map(), digest(), Actor.t()) ::
          {:created | :key_conflict | :tenant_inactive, Relay.Id.t() | nil, pos_integer() | nil}
  def create(attrs, digest, %Actor{} = actor) do
    params = [attrs.id, attrs.key, attrs.name, attrs.tree, digest] ++ Actor.params(actor)
    [row] = Repo.call!("relay_fn.route_create", params)

    {Repo.code!(row["result"], [:created, :key_conflict, :tenant_inactive]), row["route_id"],
     row["version"]}
  end

  # WF-14
  @doc "Replaces the name and tree of a route under its version; the same name and tree is `:unchanged`."
  @spec replace(String.t(), map(), pos_integer() | nil, digest(), Actor.t()) ::
          {:replaced | :unchanged | :not_found | :archived | :version_conflict,
           pos_integer() | nil}
  def replace(key, attrs, expected_version, digest, %Actor{} = actor) do
    params = [key, attrs.name, attrs.tree, expected_version, digest] ++ Actor.params(actor)
    [row] = Repo.call!("relay_fn.route_replace", params)
    codes = [:replaced, :unchanged, :not_found, :archived, :version_conflict]
    {Repo.code!(row["result"], codes), row["version"]}
  end

  # WF-14
  @doc "Archives a route; a route that an active category names as its default is `:in_use`."
  @spec archive(String.t(), digest(), Actor.t()) ::
          {:archived | :already_archived | :in_use | :not_found, pos_integer() | nil}
  def archive(key, digest, %Actor{} = actor) do
    [row] = Repo.call!("relay_fn.route_archive", [key, digest] ++ Actor.params(actor))
    codes = [:archived, :already_archived, :in_use, :not_found]
    {Repo.code!(row["result"], codes), row["version"]}
  end

  @doc "Reads a route by key, or `nil`."
  @spec get(String.t()) :: map() | nil
  def get(key) do
    one("SELECT #{@columns} FROM relay.routes r WHERE r.key = $1", [key])
  end

  # WF-14
  @doc "The default route key of a category, or `nil` when the category has none or is unknown."
  @spec category_default(String.t()) :: String.t() | nil
  def category_default(category_key) do
    sql = "SELECT c.default_route FROM relay.categories c WHERE c.key = $1"

    case one(sql, [category_key]) do
      %{"default_route" => key} -> key
      nil -> nil
    end
  end

  # API-56
  @doc "Lists routes newest first, after or before a cursor position."
  @spec list(map() | nil, pos_integer()) :: [map()]
  def list(cursor, limit) do
    {condition, order, params} = position(cursor)

    sql = """
    SELECT #{@columns}, r.created_at AS cursor_at FROM relay.routes r#{condition}
    ORDER BY r.created_at #{order}, r.id #{order}
    LIMIT #{limit + 1}
    """

    rows = maps(Repo.scoped_query!(sql, params))
    if order == "ASC", do: Enum.reverse(rows), else: rows
  end

  defp position(nil), do: {"", "DESC", []}

  defp position(%{direction: :after, sort_ts_us: ts, id: id}),
    do: {" WHERE (r.created_at, r.id) < ($1, $2)", "DESC", [from_us(ts), id]}

  defp position(%{direction: :before, sort_ts_us: ts, id: id}),
    do: {" WHERE (r.created_at, r.id) > ($1, $2)", "ASC", [from_us(ts), id]}

  defp from_us(us), do: DateTime.from_unix!(us, :microsecond)

  defp one(sql, params) do
    case maps(Repo.scoped_query!(sql, params)) do
      [row] -> row
      [] -> nil
    end
  end

  defp maps(%Postgrex.Result{columns: columns, rows: rows}),
    do: Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
end
