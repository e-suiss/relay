defmodule Relay.Datasets do
  @moduledoc """
  Versioned data sets: tables that are data, not code (CH-18), held by one mechanism (OP-65). A data set has a name, a JSON Schema 2020-12 document and the scopes it may be published in (installation, tenant); data sets are defined by migrations. Each version is an immutable row; each scope has at most one active version, and activating one is an audited write. A decision made from a data set records the version it used (`decide/3`) and can be reproduced from it (`replay/3`).

  Active versions are cached on every node. An activation commits in PostgreSQL first and then signals the nodes over Valkey, which drop their cached entry; PostgreSQL stays the truth (T-9). Installation-wide versions live under the installation tenant's `live` environment (S-3) and are readable from every scope. Other contexts use only the functions of this module.
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Platform, Relay.Platform.Leadership, Relay.Audit],
    exports: []

  require Logger

  alias Relay.Actor
  alias Relay.Datasets.Cache
  alias Relay.Datasets.Package
  alias Relay.Datasets.Schema
  alias Relay.Datasets.Store
  alias Relay.Datasets.Version
  alias Relay.Scope

  @installation_key {__MODULE__, :installation_tenant_id}

  @type source :: :package | :operator
  @type publish_result :: :published | :exists | :dataset_not_found | :scope_not_allowed
  @type activate_result :: :activated | :already_active | :version_not_found | :operator_pinned

  @doc "Supervised children: the node-local cache of active versions."
  @spec children() :: [Supervisor.child_spec()]
  def children, do: [Supervisor.child_spec(Cache, [])]

  @doc "Returns the installation scope: the installation tenant's `live` environment."
  @spec installation_scope() :: Scope.t()
  def installation_scope, do: Scope.new!(installation_tenant_id(), :live)

  defp installation_tenant_id do
    case :persistent_term.get(@installation_key, nil) do
      nil ->
        id = Store.installation_tenant_id()
        :persistent_term.put(@installation_key, id)
        id

      id ->
        id
    end
  end

  # OP-65 (3)
  # OP-65 (6)
  @doc """
  Returns the active version of a data set in `scope`, `nil` when the scope has none. Use `installation_scope/0` for an installation-wide data set. Inside a scoped transaction only the transaction's own scope and the installation scope can be read, and the read is not cached.
  """
  @spec active(Scope.t(), String.t()) :: {:ok, Version.t() | nil} | {:error, Relay.Error.t()}
  def active(%Scope{} = scope, name) when is_binary(name) do
    with :ok <- readable(scope),
         {:ok, topic} <- topic(scope, name) do
      Cache.fetch(Cache, {scope, name}, topic, fn -> load_active(scope, name) end,
        cache: not Store.scoped?()
      )
    end
  end

  defp load_active(scope, name) do
    read(scope, fn -> scope |> Store.active(name) |> version() end)
  end

  # OP-65 (4)
  @doc "Reads one version of a data set in `scope` by its identifier, active or not."
  @spec version(Scope.t(), String.t(), Relay.Id.t()) ::
          {:ok, Version.t() | nil} | {:error, Relay.Error.t()}
  def version(%Scope{} = scope, name, id) when is_binary(name) do
    with :ok <- readable(scope),
         do: read(scope, fn -> scope |> Store.version(name, id) |> version() end)
  end

  defp version(nil), do: nil
  defp version(row), do: Version.from_row(row)

  defp read(scope, fun) do
    if Store.scoped?(), do: {:ok, fun.()}, else: scoped(scope, fun)
  end

  defp readable(scope) do
    current = Store.current_scope()

    if current == nil or current == scope or scope == installation_scope(),
      do: :ok,
      else:
        {:error, Relay.Error.new(:scope_mismatch, "another scope's data set cannot be read here")}
  end

  # OP-65 (4)
  @doc """
  Runs `decide` on the content of the active version of a data set and returns its result together with the version reference the decision records. A scope without an active version is an error, never an empty table.
  """
  @spec decide(Scope.t(), String.t(), (term() -> result)) ::
          {:ok, {result, Version.ref()}} | {:error, Relay.Error.t()}
        when result: term()
  def decide(%Scope{} = scope, name, decide) when is_function(decide, 1) do
    case active(scope, name) do
      {:ok, %Version{} = version} -> {:ok, {decide.(version.content), ref(version)}}
      {:ok, nil} -> {:error, no_active(name)}
      {:error, error} -> {:error, error}
    end
  end

  # OP-65 (4)
  @doc "Runs `decide` again on the version a decision recorded, so the decision can be reproduced."
  @spec replay(Scope.t(), Version.ref(), (term() -> result)) ::
          {:ok, result} | {:error, Relay.Error.t()}
        when result: term()
  def replay(
        %Scope{} = scope,
        %{"dataset" => name, "version_id" => external, "level" => level},
        decide
      )
      when is_function(decide, 1) do
    target = if level == "installation", do: installation_scope(), else: scope

    with {:ok, id} <- Relay.ExternalId.decode(external, ["dsv"]),
         {:ok, %Version{} = version} <- version(target, name, id) do
      {:ok, decide.(version.content)}
    else
      {:ok, nil} -> {:error, Relay.Error.new(:not_found, "data set version not found")}
      {:error, error} -> {:error, error}
    end
  end

  @doc "Returns the reference of a version that a decision records."
  @spec ref(Version.t()) :: Version.ref()
  def ref(%Version{} = version), do: Version.ref(version, installation_tenant_id())

  # OP-65 (1)
  # OP-65 (2)
  @doc """
  Publishes a new version of a data set in `scope` after validating it against the data set's JSON Schema. Content that is already published returns the existing version. `opts`: `:source` (`:operator`, the default, or `:package`), `:source_ref` (required) and `:valid_from` (defaults to now).
  """
  @spec publish(Scope.t(), String.t(), Schema.json(), Actor.t(), keyword()) ::
          {:ok, {publish_result(), Relay.Id.t() | nil, pos_integer() | nil}}
          | {:error, Relay.Error.t()}
  def publish(%Scope{} = scope, name, content, %Actor{} = actor, opts \\ []) do
    source = Keyword.get(opts, :source, :operator)

    with {:ok, definition} <- definition(scope, name),
         {:ok, root} <- Schema.build(definition["json_schema"]),
         :ok <- Schema.validate(root, content),
         :ok <- consistent(name, content),
         {:ok, content_digest} <- Schema.digest(content) do
      id = Relay.Id.generate()

      attrs = %{
        id: id,
        dataset_name: name,
        content: content,
        content_digest: content_digest,
        source: Atom.to_string(source),
        source_ref: Keyword.fetch!(opts, :source_ref),
        valid_from: Keyword.get_lazy(opts, :valid_from, &Relay.Clock.utc_now/0)
      }

      digest = record_digest(scope, "dataset.version_published", actor, id, nil)
      scoped(scope, fn -> Store.publish(attrs, digest, actor) end)
    end
  end

  # CH-69
  @doc "Checks the rules of a data set's content that its JSON Schema cannot express; only `channel_parameters` has such rules."
  @spec consistent(String.t(), Schema.json()) :: :ok | {:error, Relay.Error.t()}
  def consistent("channel_parameters", content) when is_map(content),
    do: Relay.ChannelParameters.validate(content)

  def consistent(_name, _content), do: :ok

  # CH-69
  # OP-65 (4)
  @doc "Returns the active `channel_parameters` version as a `Relay.ChannelParameters` snapshot; an installation without an active version is an error."
  @spec channel_parameters() :: {:ok, Relay.ChannelParameters.t()} | {:error, Relay.Error.t()}
  def channel_parameters do
    case active(installation_scope(), "channel_parameters") do
      {:ok, %Version{} = version} ->
        {:ok, Relay.ChannelParameters.new(version.content, version.id)}

      {:ok, nil} ->
        {:error, no_active("channel_parameters")}

      {:error, error} ->
        {:error, error}
    end
  end

  defp definition(scope, name) do
    case scoped(scope, fn -> Store.dataset(name) end) do
      {:ok, nil} -> {:error, Relay.Error.new(:dataset_not_found, "data set not found")}
      other -> other
    end
  end

  # OP-65 (3)
  # OP-65 (5)
  # OP-65 (6)
  # TN-46
  @doc """
  Activates a version of a data set in `scope`. A `:package` activation never replaces an active operator version (`:operator_pinned`). After the activation commits, every node is signalled to drop its cached version.
  """
  @spec activate(Scope.t(), String.t(), Relay.Id.t(), source(), Actor.t()) ::
          {:ok, activate_result()} | {:error, Relay.Error.t()}
  def activate(%Scope{} = scope, name, version_id, source, %Actor{} = actor)
      when source in [:package, :operator] do
    digest =
      record_digest(scope, "dataset.activated", actor, version_id, Atom.to_string(source))

    with {:ok, result} <-
           scoped(scope, fn ->
             Store.activate(name, version_id, Atom.to_string(source), digest, actor)
           end) do
      if result == :activated, do: announce(scope, name)
      {:ok, result}
    end
  end

  defp announce(scope, name) do
    :ok = Cache.invalidate(Cache, {scope, name})

    with {:ok, topic} <- topic(scope, name),
         {:error, error} <- Relay.Platform.publish_signal(topic, 0) do
      Logger.warning("data set activation signal not sent", dataset: name, code: error.code)
    end

    :ok
  end

  # OP-65 (5)
  @doc """
  Publishes the data set versions Relay ships (`Relay.Datasets.Package`) in the installation scope. A version whose content is already published is left as it is; when a run publishes a new version, or the data set has no active version yet, the highest-numbered packaged version is activated as a package activation, so an operator's version stays active. Every data set must be defined by a migration with the same schema and allow the installation scope.
  """
  @spec load_package(Path.t(), Actor.t()) ::
          {:ok, %{String.t() => %{published: [pos_integer()], activation: atom()}}}
          | {:error, Relay.Error.t()}
  def load_package(root \\ Package.root(), %Actor{} = actor) do
    with {:ok, datasets} <- Package.read(root),
         do: Enum.reduce_while(datasets, {:ok, %{}}, &load_into(&1, &2, actor))
  end

  defp load_into(dataset, {:ok, report}, actor) do
    case load_dataset(dataset, actor) do
      {:ok, outcome} -> {:cont, {:ok, Map.put(report, dataset.name, outcome)}}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp load_dataset(dataset, actor) do
    scope = installation_scope()

    with {:ok, definition} <- definition(scope, dataset.name),
         :ok <- same_schema(definition, dataset),
         {:ok, published, last} <- publish_versions(scope, dataset, actor),
         {:ok, activation} <- activate_last(scope, dataset.name, last, published, actor) do
      {:ok, %{published: published, activation: activation}}
    end
  end

  defp same_schema(definition, dataset) do
    cond do
      definition["json_schema_digest"] != dataset.schema_digest ->
        package_error(dataset.name, "the packaged schema differs from the defined schema")

      "installation" not in definition["allowed_scopes"] ->
        package_error(dataset.name, "the data set does not allow the installation scope")

      true ->
        :ok
    end
  end

  defp publish_versions(scope, dataset, actor) do
    Enum.reduce_while(dataset.versions, {:ok, [], nil}, fn v, {:ok, published, _last} ->
      opts = [source: :package, source_ref: source_ref(dataset.name, v.no)]

      case publish(scope, dataset.name, v.content, actor, opts) do
        {:ok, {:published, id, _no}} -> {:cont, {:ok, published ++ [v.no], id}}
        {:ok, {:exists, id, _no}} -> {:cont, {:ok, published, id}}
        {:ok, {result, _id, _no}} -> {:halt, package_error(dataset.name, "publish: #{result}")}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp activate_last(scope, name, last, published, actor) do
    with {:ok, current} <- active(scope, name) do
      if published != [] or current == nil,
        do: activate(scope, name, last, :package, actor),
        else: {:ok, :unchanged}
    end
  end

  defp source_ref(name, no) do
    vsn = :relay |> Application.spec(:vsn) |> to_string()
    "relay@#{vsn}:#{name}/v#{no}"
  end

  defp package_error(name, message),
    do: {:error, Relay.Error.new(:invalid_package, message, %{dataset: name})}

  defp no_active(name),
    do:
      Relay.Error.new(:no_active_version, "the data set has no active version", %{dataset: name})

  defp scoped(scope, fun) do
    case Store.in_scope(scope, fn _status -> fun.() end) do
      {:ok, result} -> {:ok, result}
      {:error, %Relay.Error{} = error} -> {:error, error}
    end
  end

  defp topic(scope, name),
    do:
      Relay.Platform.signal_topic(
        Scope.tenant_text(scope),
        Relay.Environment.dump(scope.environment),
        [
          "dataset",
          name
        ]
      )

  defp record_digest(scope, action, actor, target_id, reason) do
    Relay.Audit.record_digest(%{
      tenant_id: scope.tenant_id,
      environment: Relay.Environment.dump(scope.environment),
      action: action,
      actor_kind: Atom.to_string(actor.kind),
      actor_ref: actor.ref,
      on_behalf_of_ref: actor.on_behalf_of_ref,
      access_record_ref: actor.access_record_ref,
      target_type: "dataset_version",
      target_id: Relay.Id.to_string(target_id),
      reason: reason
    })
  end
end
