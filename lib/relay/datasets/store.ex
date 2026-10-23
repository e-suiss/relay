defmodule Relay.Datasets.Store do
  @moduledoc """
  Data access for versioned data sets. Writes call `relay_fn.dataset_version_publish` and `relay_fn.dataset_activate`; reads run in the caller's scoped transaction when there is one and in their own otherwise. Rows of the installation tenant's `live` environment are readable from every scope (S-3).
  """

  alias Relay.Actor
  alias Relay.Repo
  alias Relay.Scope

  @version_columns "v.tenant_id, v.environment, v.id, v.dataset_name, v.version_no, v.content, v.content_digest, v.source, v.source_ref, v.valid_from, v.created_at"

  @type digest :: <<_::256>>

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  @doc "Returns true if the calling process is inside a scoped transaction."
  @spec scoped?() :: boolean()
  def scoped?, do: Repo.current_scope() != nil

  @doc "Returns the scope of the calling process's transaction, or nil."
  @spec current_scope() :: Scope.t() | nil
  def current_scope, do: Repo.current_scope()

  @doc "Reads the installation tenant's identifier through the installation lookup escape hatch."
  @spec installation_tenant_id() :: Relay.Id.t()
  def installation_tenant_id do
    {:ok, %Postgrex.Result{rows: [[id]]}} =
      if scoped?(),
        do: Repo.scoped_query("SELECT relay_private.installation_tenant_id()", []),
        else:
          Repo.unscoped_query(
            :installation_lookup,
            "SELECT installation_tenant_id FROM relay.installation",
            []
          )

    id
  end

  # OP-65 (1)
  @doc "Reads a data set definition: its JSON Schema, schema digest and allowed scopes."
  @spec dataset(String.t()) :: map() | nil
  def dataset(name) do
    "SELECT name, json_schema, json_schema_digest, allowed_scopes FROM relay.datasets WHERE name = $1"
    |> Repo.scoped_query!([name])
    |> rows()
    |> List.first()
  end

  # OP-65 (3)
  @doc "Reads the active version of a data set in `scope`; inside the caller's transaction the scope must be the transaction's own or the installation's."
  @spec active(Scope.t(), String.t()) :: map() | nil
  def active(%Scope{} = scope, name) do
    """
    SELECT #{@version_columns}, a.activated_at
    FROM relay.dataset_active a
    JOIN relay.dataset_versions v
      ON v.tenant_id = a.tenant_id AND v.environment = a.environment AND v.id = a.version_id
    WHERE a.tenant_id = $1 AND a.environment = $2 AND a.dataset_name = $3
    """
    |> Repo.scoped_query!(params(scope, [name]), shared: :installation)
    |> rows()
    |> List.first()
  end

  # OP-65 (4)
  @doc "Reads one version of a data set in `scope` by its identifier."
  @spec version(Scope.t(), String.t(), Relay.Id.t()) :: map() | nil
  def version(%Scope{} = scope, name, id) do
    """
    SELECT #{@version_columns}
    FROM relay.dataset_versions v
    WHERE v.tenant_id = $1 AND v.environment = $2 AND v.dataset_name = $3 AND v.id = $4
    """
    |> Repo.scoped_query!(params(scope, [name, id]), shared: :installation)
    |> rows()
    |> List.first()
  end

  # OP-65 (5)
  @doc "Reads the content digests of the versions of a data set in `scope` that came from the package."
  @spec package_digests(Scope.t(), String.t()) :: MapSet.t(digest())
  def package_digests(%Scope{} = scope, name) do
    "SELECT v.tenant_id, v.environment, v.content_digest FROM relay.dataset_versions v WHERE v.tenant_id = $1 AND v.environment = $2 AND v.dataset_name = $3 AND v.source = 'package'"
    |> Repo.scoped_query!(params(scope, [name]), shared: :installation)
    |> rows()
    |> MapSet.new(& &1["content_digest"])
  end

  # OP-65 (2)
  @doc "Publishes a version in the established scope; content that is already published returns the existing version."
  @spec publish(map(), digest(), Actor.t()) ::
          {:published | :exists | :dataset_not_found | :scope_not_allowed, Relay.Id.t() | nil,
           pos_integer() | nil}
  def publish(attrs, record_digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.dataset_version_publish",
        [
          attrs.id,
          attrs.dataset_name,
          attrs.content,
          attrs.content_digest,
          attrs.source,
          attrs.source_ref,
          attrs.valid_from,
          record_digest
        ] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [:published, :exists, :dataset_not_found, :scope_not_allowed]),
     row["version_id"], row["version_no"]}
  end

  # OP-65 (3)
  # OP-65 (5)
  @doc "Activates a version in the established scope; a package activation never replaces an operator version."
  @spec activate(String.t(), Relay.Id.t(), String.t(), digest(), Actor.t()) ::
          :activated | :already_active | :version_not_found | :operator_pinned
  def activate(name, version_id, source, record_digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.dataset_activate",
        [name, version_id, source, record_digest] ++ Actor.params(actor)
      )

    Repo.code!(row["dataset_activate"], [
      :activated,
      :already_active,
      :version_not_found,
      :operator_pinned
    ])
  end

  defp params(%Scope{tenant_id: tenant_id, environment: environment}, rest),
    do: [tenant_id, Relay.Environment.dump(environment) | rest]

  defp rows(%Postgrex.Result{columns: columns, rows: rows}),
    do: Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
end
