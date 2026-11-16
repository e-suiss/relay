defmodule Relay.Webhooks.SourceStore do
  @moduledoc """
  Data access of completion sources (WH-68): the external systems that notify Relay when a long-running job ends. A source is written only through `relay_fn.webhook_source_create` and `relay_fn.webhook_source_archive` and is never deleted; it holds a public key or the identifier of a secret reference, never a secret. Every function runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  @type id :: Relay.Id.t()
  @type cursor :: map() | nil

  @created ~w(created secret_not_found limit_reached tenant_inactive)a
  @archived ~w(archived already_archived not_found)a
  @columns "w.id, w.name, w.scheme, w.public_key, w.secret_ref_id, w.state, w.archived_at, w.created_at, w.updated_at"

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # WH-68
  @doc "Registers a source; `attrs` carries `:name`, `:scheme` and the `:public_key` bytes or the `:secret_ref_id`, and `limit` is how many sources that are not archived the environment may hold. Returns the result and the source's identifier."
  @spec create(map(), pos_integer(), binary(), Actor.t()) :: {atom(), id() | nil}
  def create(attrs, limit, digest, %Actor{} = actor) do
    params =
      [
        Relay.Id.generate(),
        attrs.name,
        attrs.scheme,
        Map.get(attrs, :public_key),
        Map.get(attrs, :secret_ref_id),
        limit,
        digest
      ] ++ Actor.params(actor)

    [row] = Repo.call!("relay_fn.webhook_source_create", params)
    {Repo.code!(row["result"], @created), row["source_id"]}
  end

  # WH-68
  @doc "Archives a source."
  @spec archive(id(), binary(), Actor.t()) :: :archived | :already_archived | :not_found
  def archive(id, digest, %Actor{} = actor) do
    [row] = Repo.call!("relay_fn.webhook_source_archive", [id, digest] ++ Actor.params(actor))
    Repo.code!(row["webhook_source_archive"], @archived)
  end

  # WH-68
  @doc "Reads a source, or `nil`."
  @spec get(id()) :: map() | nil
  def get(id) do
    case all("SELECT #{@columns} FROM relay.webhook_sources w WHERE w.id = $1", [id]) do
      [row] -> row
      [] -> nil
    end
  end

  # WH-68
  # API-56
  @doc "A page of sources, newest first, optionally of one state; at most `limit + 1` rows, each with its `cursor_at`."
  @spec list(String.t() | nil, cursor(), pos_integer()) :: [map()]
  def list(state, cursor, limit) do
    {condition, order, params} = window(cursor, [state])

    sql = """
    SELECT #{@columns}, w.created_at AS cursor_at FROM relay.webhook_sources w
    WHERE ($1::text IS NULL OR w.state = $1)#{condition}
    ORDER BY w.created_at #{order}, w.id #{order}
    LIMIT #{limit + 1}
    """

    rows = all(sql, params)
    if order == "ASC", do: Enum.reverse(rows), else: rows
  end

  defp window(nil, params), do: {"", "DESC", params}

  defp window(%{direction: :after, sort_ts_us: ts, id: id}, params),
    do: {" AND (w.created_at, w.id) < ($2, $3)", "DESC", params ++ [from_us(ts), id]}

  defp window(%{direction: :before, sort_ts_us: ts, id: id}, params),
    do: {" AND (w.created_at, w.id) > ($2, $3)", "ASC", params ++ [from_us(ts), id]}

  defp from_us(us), do: DateTime.from_unix!(us, :microsecond)

  defp all(sql, params) do
    %{rows: rows, columns: columns} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
