defmodule Relay.Workflow do
  @moduledoc """
  Workflows, steps, routing, escalation and scheduling. Other contexts use only the functions of this module.

  In stage 3 a workflow is a registry entry with immutable versions (WF-5): a draft is replaced as a whole, a publication request moves it to the publication gate (`Relay.Workflow.PublishGate`), and a published version never changes (INV-48). Going back to an old version publishes its definition again as a new version (WF-6). A definition is data (C-40): its event schema, its message class and category, and its channel steps; nothing in it runs as customer code.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Actor
  alias Relay.Scope
  alias Relay.Workflow.ContentDedup
  alias Relay.Workflow.Definition
  alias Relay.Workflow.Digest
  alias Relay.Workflow.PublishGate
  alias Relay.Workflow.Store
  alias Relay.Workflow.Throttle

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

  # TP-13
  # TP-32
  @doc "The active workflows whose published version sends the template key in a channel step, inside the caller's scoped transaction: each with its `key`, `version_no` and `event_schema`."
  @spec using_template(String.t()) :: [map()]
  defdelegate using_template(template_key), to: Store

  # WF-26
  # WF-27
  # INV-3
  @doc "Adds an event to its digest window inside the caller's scoped transaction; see `Relay.Workflow.Digest.add/2`."
  @spec digest_add(Scope.t(), map()) :: {:ok, Digest.added()} | {:error, Relay.Error.t()}
  defdelegate digest_add(scope, attrs), to: Digest, as: :add

  # WF-26
  # WF-59
  @doc "Checks the fields of a `digest` step; see `Relay.Workflow.Digest.Window.config/2`."
  @spec digest_config(map(), String.t()) ::
          {:ok, Digest.Window.t()} | {:error, [Digest.Window.field_error(), ...]}
  defdelegate digest_config(step, pointer \\ ""), to: Digest.Window, as: :config

  # WF-27
  @doc "Fires a digest window in its own transaction; see `Relay.Workflow.Digest.fire/2`."
  @spec digest_fire(Scope.t(), Relay.Id.t()) :: {:ok, term()} | {:error, term()}
  defdelegate digest_fire(scope, window_id), to: Digest, as: :fire

  # WF-27
  @doc "Applies a recipient's read signal to the pending digest windows of a notification; see `Relay.Workflow.Digest.read/3`."
  @spec digest_read(Scope.t(), Relay.Id.t(), Relay.Id.t()) ::
          {:ok, [{Relay.Id.t(), :cancelled | :read}]} | {:error, term()}
  defdelegate digest_read(scope, recipient_id, notification_id), to: Digest, as: :read

  # WF-30
  @doc "Routes an event into a digest window past the recipient's density threshold; see `Relay.Workflow.Digest.density/2`."
  @spec digest_density(Scope.t(), map()) ::
          {:ok, :under | Digest.added()} | {:error, Relay.Error.t()}
  defdelegate digest_density(scope, attrs), to: Digest, as: :density

  # PC-46
  @doc "Holds a delivery released at the end of quiet hours in its morning window; see `Relay.Workflow.Digest.quiet_hours/2`."
  @spec digest_quiet_hours(Scope.t(), map()) ::
          {:ok, :not_applicable | Digest.added()} | {:error, Relay.Error.t()}
  defdelegate digest_quiet_hours(scope, attrs), to: Digest, as: :quiet_hours

  # T-24
  # TN-8
  @doc "Fires the due digest windows of a scope; the virtual clock tick calls it after a step."
  @spec run_due_digests(Scope.t()) :: :ok | {:error, term()}
  defdelegate run_due_digests(scope), to: Digest, as: :run_due

  # WF-32
  # WF-59
  @doc "Checks the fields of a `throttle` step; see `Relay.Workflow.Throttle.Window.config/2`."
  @spec throttle_config(map(), String.t()) ::
          {:ok, Throttle.Window.t()} | {:error, [Throttle.Window.field_error(), ...]}
  defdelegate throttle_config(step, pointer \\ ""), to: Throttle, as: :config

  # WF-32
  @doc "Counts an event against a throttle step inside the caller's scoped transaction; see `Relay.Workflow.Throttle.hit/3`."
  @spec throttle(Scope.t(), map(), map()) :: {:ok, Throttle.hit()} | {:error, Relay.Error.t()}
  defdelegate throttle(scope, step, attrs), to: Throttle, as: :hit

  # WF-32
  @doc "Counts an event against a throttle step in its own transaction; see `Relay.Workflow.Throttle.hit_now/3`."
  @spec throttle_now(Scope.t(), map(), map()) :: {:ok, Throttle.hit()} | {:error, term()}
  defdelegate throttle_now(scope, step, attrs), to: Throttle, as: :hit_now

  # WF-32
  # API-69
  @doc "Resets the active counter of a throttle key inside the caller's scoped transaction, audited."
  @spec reset_throttle(Scope.t(), String.t(), Actor.t()) ::
          {:ok, {:reset | :not_active, Relay.Id.t() | nil}} | {:error, Relay.Error.t()}
  def reset_throttle(%Scope{} = scope, key, %Actor{} = actor),
    do: Throttle.reset(scope, key, digest(scope, "throttle.reset", key), actor)

  # WF-35
  # WF-36
  @doc "The content deduplication step of the delivery job, configured as `config :relay, Relay.Delivery, content_dedup: Module`: checks a rendered delivery for a content repeat and records a repeat as skipped; see `Relay.Workflow.ContentDedup.check/2`."
  @spec content_dedup(Scope.t(), Relay.Id.t()) :: :send | :skipped | {:error, term()}
  defdelegate content_dedup(scope, delivery_id), to: ContentDedup, as: :check

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
