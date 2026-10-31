defmodule Relay.Workflow do
  @moduledoc """
  Workflows, steps, routing, escalation and scheduling. Other contexts use only the functions of this module.

  In stage 3 a workflow is a registry entry with immutable versions (WF-5): a draft is replaced as a whole, a publication request moves it to the publication gate (`Relay.Workflow.PublishGate`), and a published version never changes (INV-48). Going back to an old version publishes its definition again as a new version (WF-6). A definition is data (C-40): its event schema, its message class and category, and its channel steps; nothing in it runs as customer code.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Actor
  alias Relay.Scope
  alias Relay.Workflow.Definition
  alias Relay.Workflow.PublishGate
  alias Relay.Workflow.Store

  @gate %Actor{kind: :system, ref: "relay:publish_gate", on_behalf_of_ref: "relay"}

  @type result(value) :: {:ok, value} | {:error, term()}
  @type version :: pos_integer() | nil

  # WF-1
  # WF-5
  @doc "Creates a workflow and its first draft from a key and a definition, inside the caller's scoped transaction."
  @spec create(Scope.t(), String.t(), Definition.t(), Actor.t()) ::
          {:ok, {:created | :key_conflict | :tenant_inactive, Relay.Id.t() | nil, term()}}
  def create(%Scope{} = scope, key, definition, %Actor{} = actor) do
    attrs =
      definition
      |> attrs()
      |> Map.merge(%{id: Relay.Id.generate(), key: key, draft_id: Relay.Id.generate()})

    {:ok, Store.create(attrs, digest(scope, "workflow.created", key), actor)}
  end

  # WF-5
  @doc "Replaces the draft of a workflow inside the caller's scoped transaction; `expected_version` is the workflow's ETag version."
  @spec replace_draft(Scope.t(), String.t(), Definition.t(), pos_integer() | nil, Actor.t()) ::
          {:ok, {:replaced | :unchanged | :version_conflict | :not_found, term()}}
  def replace_draft(%Scope{} = scope, key, definition, expected_version, %Actor{} = actor) do
    attrs = Map.put(attrs(definition), :draft_id, Relay.Id.generate())

    {:ok,
     Store.draft_put(key, attrs, expected_version, digest(scope, "workflow.drafted", key), actor)}
  end

  # WF-6
  @doc "Sends the draft to the publication gate inside the caller's scoped transaction; the gate job is queued in the same transaction."
  @spec request_publication(Scope.t(), String.t(), version(), String.t() | nil, Actor.t()) ::
          {:ok, {atom(), Relay.Id.t() | nil}}
  def request_publication(%Scope{} = scope, key, expected_version, note, %Actor{} = actor) do
    digest = digest(scope, "workflow.publication_requested", key)

    case Store.publish_request(key, expected_version, note, digest, actor) do
      {:pending, version_id} ->
        :ok = Store.insert_job!(PublishGate.job(scope, version_id))
        {:ok, {:pending, version_id}}

      other ->
        {:ok, other}
    end
  end

  # WF-6
  @doc "Publishes an old version's definition again as a new version, through the gate, inside the caller's scoped transaction."
  @spec promote(Scope.t(), String.t(), pos_integer(), Actor.t()) ::
          {:ok, {atom(), Relay.Id.t() | nil}}
  def promote(%Scope{} = scope, key, version_no, %Actor{} = actor) do
    digest = digest(scope, "workflow.promoted", key)

    case Store.promote(key, version_no, Relay.Id.generate(), digest, actor) do
      {:pending, version_id} ->
        :ok = Store.insert_job!(PublishGate.job(scope, version_id))
        {:ok, {:pending, version_id}}

      other ->
        {:ok, other}
    end
  end

  # WF-6
  # INV-48
  @doc "Runs the publication gate of a pending version: publishes it as the next version number or rejects it with field errors."
  @spec run_gate(Scope.t(), Relay.Id.t()) ::
          result({:published | :rejected | :not_pending, term()})
  def run_gate(%Scope{} = scope, version_id) do
    Store.in_scope(scope, fn _status ->
      case Store.version(version_id) do
        %{"state" => "pending", "definition" => definition} ->
          {outcome, errors} = gate_outcome(Definition.gate(definition))
          digest = digest(scope, "workflow.published", Relay.Id.to_string(version_id))
          Store.publish_complete(version_id, outcome, errors, digest, @gate)

        _other ->
          {:not_pending, nil}
      end
    end)
  end

  defp gate_outcome([]), do: {:published, nil}
  defp gate_outcome(errors), do: {:rejected, Enum.map(errors, &stringify/1)}

  # WF-5
  @doc "Reads a workflow with its draft and its last publication; `nil` when the key is unknown."
  @spec get(Scope.t(), String.t()) :: result(map() | nil)
  def get(%Scope{} = scope, key) do
    Store.in_scope(scope, fn _status ->
      case Store.get(key) do
        nil -> nil
        workflow -> with_parts(workflow)
      end
    end)
  end

  # WF-5
  @doc "Reads a workflow with its draft and its last publication inside the caller's scoped transaction; `nil` when the key is unknown."
  @spec view(String.t()) :: map() | nil
  def view(key) do
    case Store.get(key) do
      nil -> nil
      workflow -> with_parts(workflow)
    end
  end

  # API-56
  @doc "Lists workflows newest first from a decoded cursor; at most `limit + 1` rows come back."
  @spec list(Scope.t(), map() | nil, pos_integer()) :: result([map()])
  def list(%Scope{} = scope, cursor, limit) do
    Store.in_scope(scope, fn _status -> Enum.map(Store.list(cursor, limit), &with_parts/1) end)
  end

  # API-56
  @doc "Lists the published versions of a workflow; `nil` when the key is unknown."
  @spec list_versions(Scope.t(), String.t(), map() | nil, pos_integer()) :: result([map()] | nil)
  def list_versions(%Scope{} = scope, key, cursor, limit) do
    Store.in_scope(scope, fn _status ->
      case Store.get(key) do
        nil -> nil
        workflow -> Store.list_versions(workflow["id"], cursor, limit)
      end
    end)
  end

  # WF-6
  @doc "Reads a published version by number; `{:ok, :workflow_not_found}` or `{:ok, :version_not_found}` when missing."
  @spec get_version(Scope.t(), String.t(), pos_integer()) ::
          result(map() | :workflow_not_found | :version_not_found)
  def get_version(%Scope{} = scope, key, version_no) do
    Store.in_scope(scope, fn _status ->
      case Store.get(key) do
        nil ->
          :workflow_not_found

        workflow ->
          Store.published_version(workflow["id"], version_no) || :version_not_found
      end
    end)
  end

  # WF-7
  # API-27
  @doc "Resolves the published version of a key inside the caller's scoped transaction; `:not_found` for an unknown key, `:not_published` for a workflow without a published version."
  @spec resolve(String.t()) :: {:ok, map()} | :not_found | :not_published
  def resolve(key) do
    case Store.resolve(key) do
      nil -> if Store.get(key), do: :not_published, else: :not_found
      row -> {:ok, Map.put(row, "key", key)}
    end
  end

  # WF-7
  @doc "Resolves the published version of a key in its own read transaction."
  @spec resolve_published(Scope.t(), String.t()) ::
          result({:ok, map()} | :not_found | :not_published)
  def resolve_published(%Scope{} = scope, key),
    do: Store.in_scope(scope, fn _status -> resolve(key) end)

  # API-28
  @doc "Resolves the published version of a workflow by its identifier in its own read transaction."
  @spec resolve_published_id(Scope.t(), Relay.Id.t()) ::
          result({:ok, map()} | :not_found | :not_published)
  def resolve_published_id(%Scope{} = scope, workflow_id) do
    Store.in_scope(scope, fn _status ->
      case Store.get_by_id(workflow_id) do
        nil -> :not_found
        workflow -> resolve(workflow["key"])
      end
    end)
  end

  # WF-1
  # API-27
  @doc "Builds the validator of an event schema; see `Relay.Workflow.Definition.event_schema/1`."
  @spec event_schema(map()) :: {:ok, JSV.Root.t()} | {:error, String.t()}
  defdelegate event_schema(schema), to: Definition

  # WF-8
  @doc "The channel steps of a definition; see `Relay.Workflow.Definition.steps/1`."
  @spec steps(Definition.t()) :: [map()]
  defdelegate steps(definition), to: Definition

  # TN-65 (3)
  @doc "The digest of a definition; see `Relay.Workflow.Definition.digest/1`."
  @spec definition_digest(Definition.t()) :: <<_::256>>
  defdelegate definition_digest(definition), to: Definition, as: :digest

  defp with_parts(workflow) do
    Map.merge(workflow, %{
      "draft" => Store.draft(workflow["id"]),
      "publication" => Store.last_publication(workflow["id"])
    })
  end

  defp attrs(definition) do
    %{
      name: definition["name"],
      definition: definition,
      definition_digest: Definition.digest(definition),
      event_schema: definition["event_schema"],
      message_class: definition["message_class"],
      category: definition["category"]
    }
  end

  defp stringify(error), do: Map.new(error, fn {key, value} -> {Atom.to_string(key), value} end)

  defp digest(scope, action, ref) do
    environment = Atom.to_string(scope.environment)

    :crypto.hash(
      :sha256,
      Relay.Canonical.encode!([action, {:bytes, scope.tenant_id}, environment, ref])
    )
  end
end
