defmodule Relay.Workflow.Store do
  @moduledoc """
  Data access of workflows and their versions. Writes call the `relay_fn.workflow_*` functions; reads select the workflow, its draft, its pending or last finished publication and its published versions. Every function except `in_scope/2` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  @type digest :: <<_::256>>
  @type version :: pos_integer() | nil
  @type outcome :: :published | :rejected

  @workflow_columns """
  w.id, w.key, w.name, w.managed_by, w.state, w.published_version_no, w.version, w.created_at,
  w.updated_at
  """

  @version_columns """
  v.id, v.workflow_id, v.state, v.version_no, v.definition, v.definition_digest,
  v.promoted_from_version_no, v.publication_errors, v.requested_at, v.published_at,
  v.published_by_ref, v.updated_at
  """

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  @doc "Queues a job inside the current transaction; rolls the transaction back when it is not queued."
  @spec insert_job!(Ecto.Changeset.t()) :: :ok
  def insert_job!(changeset) do
    case Oban.insert(changeset) do
      {:ok, _job} -> :ok
      {:error, reason} -> Repo.rollback({:job_not_queued, reason})
    end
  end

  # WF-1
  # WF-5
  @doc "Creates a workflow with its first draft."
  @spec create(map(), <<_::256>>, Actor.t()) ::
          {:created | :key_conflict | :tenant_inactive, Relay.Id.t() | nil, pos_integer() | nil}
  def create(attrs, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.workflow_create",
        [
          attrs.id,
          attrs.key,
          attrs.name,
          attrs.draft_id,
          attrs.definition,
          attrs.definition_digest,
          attrs.event_schema,
          attrs.message_class,
          attrs.category,
          digest
        ] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [:created, :key_conflict, :tenant_inactive]), row["workflow_id"],
     row["version"]}
  end

  # WF-5
  @doc "Replaces the draft of a workflow by a new draft row; the same definition and name is `:unchanged`."
  @spec draft_put(String.t(), map(), pos_integer() | nil, <<_::256>>, Actor.t()) ::
          {:replaced | :unchanged | :version_conflict | :not_found, pos_integer() | nil}
  def draft_put(key, attrs, expected_version, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.workflow_draft_put",
        [
          key,
          attrs.draft_id,
          attrs.name,
          attrs.definition,
          attrs.definition_digest,
          attrs.event_schema,
          attrs.message_class,
          attrs.category,
          expected_version,
          digest
        ] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [:replaced, :unchanged, :version_conflict, :not_found]),
     row["version"]}
  end

  # WF-6
  @doc "Moves the draft to the publication gate."
  @spec publish_request(String.t(), version(), String.t() | nil, digest(), Actor.t()) ::
          {:pending | :no_draft | :already_pending | :version_conflict | :not_found,
           Relay.Id.t() | nil}
  def publish_request(key, expected_version, note, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.workflow_publish_request",
        [key, expected_version, note, digest] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [
       :pending,
       :no_draft,
       :already_pending,
       :version_conflict,
       :not_found
     ]), row["version_id"]}
  end

  # WF-6
  @doc "Republishes a published version as a new pending version."
  @spec promote(String.t(), pos_integer(), Relay.Id.t(), <<_::256>>, Actor.t()) ::
          {:pending | :version_not_found | :already_pending | :not_found, Relay.Id.t() | nil}
  def promote(key, version_no, new_id, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.workflow_promote",
        [key, version_no, new_id, digest] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [:pending, :version_not_found, :already_pending, :not_found]),
     row["version_id"]}
  end

  # WF-6
  # INV-48
  @doc "Finishes the publication gate of a pending version."
  @spec publish_complete(Relay.Id.t(), outcome(), list() | nil, digest(), Actor.t()) ::
          {:published | :rejected | :not_pending, pos_integer() | nil}
  def publish_complete(version_id, outcome, errors, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.workflow_publish_complete",
        [version_id, Atom.to_string(outcome), errors, digest] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [:published, :rejected, :not_pending]), row["version_no"]}
  end

  # WF-7
  # API-27
  @doc "Resolves the published version of a workflow key, or `nil`."
  @spec resolve(String.t()) :: map() | nil
  def resolve(key) do
    case Repo.call!("relay_fn.workflow_resolve", [key]) do
      [row] -> row
      [] -> nil
    end
  end

  @doc "Reads a workflow by key, or `nil`."
  @spec get(String.t()) :: map() | nil
  def get(key) do
    one("SELECT #{@workflow_columns} FROM relay.workflows w WHERE w.key = $1", [key])
  end

  @doc "Reads a workflow by identifier with its published version, or `nil`."
  @spec get_by_id(Relay.Id.t()) :: map() | nil
  def get_by_id(id) do
    one("SELECT #{@workflow_columns} FROM relay.workflows w WHERE w.id = $1", [id])
  end

  @doc "Reads the draft of a workflow, or `nil`."
  @spec draft(Relay.Id.t()) :: map() | nil
  def draft(workflow_id) do
    one(
      "SELECT #{@version_columns} FROM relay.workflow_versions v WHERE v.workflow_id = $1 AND v.state = 'draft'",
      [workflow_id]
    )
  end

  @doc "Reads the pending publication of a workflow, else its last finished one, or `nil`."
  @spec last_publication(Relay.Id.t()) :: map() | nil
  def last_publication(workflow_id) do
    one(
      """
      SELECT #{@version_columns} FROM relay.workflow_versions v
      WHERE v.workflow_id = $1 AND v.state IN ('pending', 'published', 'rejected')
      ORDER BY (v.state = 'pending') DESC, v.requested_at DESC NULLS LAST, v.id DESC
      LIMIT 1
      """,
      [workflow_id]
    )
  end

  @doc "Reads a version by identifier, or `nil`."
  @spec version(Relay.Id.t()) :: map() | nil
  def version(id) do
    one("SELECT #{@version_columns} FROM relay.workflow_versions v WHERE v.id = $1", [id])
  end

  @doc "Reads a published version of a workflow by its number, or `nil`."
  @spec published_version(Relay.Id.t(), pos_integer()) :: map() | nil
  def published_version(workflow_id, version_no) do
    one(
      """
      SELECT #{@version_columns} FROM relay.workflow_versions v
      WHERE v.workflow_id = $1 AND v.state = 'published' AND v.version_no = $2
      """,
      [workflow_id, version_no]
    )
  end

  # API-56
  @doc "Lists workflows newest first, after or before a cursor position."
  @spec list(map() | nil, pos_integer()) :: [map()]
  def list(cursor, limit) do
    page("relay.workflows w", @workflow_columns, "w", "TRUE", [], cursor, limit)
  end

  # API-56
  @doc "Lists the published versions of a workflow, newest first."
  @spec list_versions(Relay.Id.t(), map() | nil, pos_integer()) :: [map()]
  def list_versions(workflow_id, cursor, limit) do
    page(
      "relay.workflow_versions v",
      @version_columns,
      "v",
      "v.workflow_id = $1 AND v.state = 'published'",
      [workflow_id],
      cursor,
      limit,
      "published_at"
    )
  end

  defp page(from, columns, alias_, where, params, cursor, limit, sort \\ "created_at") do
    {condition, order, params} =
      case cursor do
        nil ->
          {"", "DESC", params}

        %{direction: :after, sort_ts_us: ts, id: id} ->
          n = length(params)

          {" AND (#{alias_}.#{sort}, #{alias_}.id) < ($#{n + 1}, $#{n + 2})", "DESC",
           params ++ [from_us(ts), id]}

        %{direction: :before, sort_ts_us: ts, id: id} ->
          n = length(params)

          {" AND (#{alias_}.#{sort}, #{alias_}.id) > ($#{n + 1}, $#{n + 2})", "ASC",
           params ++ [from_us(ts), id]}
      end

    sql = """
    SELECT #{columns}, #{alias_}.#{sort} AS cursor_at FROM #{from}
    WHERE #{where}#{condition}
    ORDER BY #{alias_}.#{sort} #{order}, #{alias_}.id #{order}
    LIMIT #{limit + 1}
    """

    rows = maps(Repo.scoped_query!(sql, params))
    if order == "ASC", do: Enum.reverse(rows), else: rows
  end

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
