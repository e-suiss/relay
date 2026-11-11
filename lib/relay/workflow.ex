defmodule Relay.Workflow do
  @moduledoc """
  Workflows, steps, routing, escalation and scheduling. Other contexts use only the functions of this module.

  A workflow is a registry entry with immutable versions (WF-5): a draft is replaced as a whole, a publication request moves it to the publication gate (`Relay.Workflow.PublishGate`, `Relay.Workflow.Definition.gate/1`), and a published version never changes (INV-48). Going back to an old version publishes its definition again as a new version (WF-6), and a published version exports as a Mermaid flowchart. A definition is data (C-40, WF-59): its event schema, its message class and category, and its step tree; nothing in it runs as customer code.

  Every workflow has one manager, `panel` or `code` (WF-4): a draft written through the panel (an operator actor) to a code-managed workflow may change only its text fields and the fields its definition lists in `controls`; changing the manager is an explicit, audited action (`set_manager/5`).

  Every notification of a workflow has one run (WF-59 (5), `Relay.Workflow.Runner`): `start_run/2` creates it at acceptance, in the accepting transaction, and advances it synchronously up to the first waiting step, opening the deliveries of the channel steps it reaches through the caller's opener. A waiting run is a row and one timer job (`Relay.Workflow.RunTimer`, WF-43); `wake/2` advances it later in its own transaction, with the opener of the configured resumer (`config :relay, Relay.Workflow, resumer: Module`, a module with `resume/2` that, outside any transaction, returns a function giving the step context and the opener inside the run's transaction). The missed-timer sweep (`Relay.Workflow.RunSweep`) wakes due runs whose timer job is missing. A run finishes on the version it started (WF-6). Cancelling an event, a notification or a cancellation key cancels its runs (`cancel_runs/1`).
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Actor
  alias Relay.Scope
  alias Relay.Workflow.Condition
  alias Relay.Workflow.Definition
  alias Relay.Workflow.PublishGate
  alias Relay.Workflow.Runner
  alias Relay.Workflow.RunStore
  alias Relay.Workflow.RunTimer
  alias Relay.Workflow.Store

  @gate %Actor{kind: :system, ref: "relay:publish_gate", on_behalf_of_ref: "relay"}

  @type result(value) :: {:ok, value} | {:error, term()}
  @type version :: pos_integer() | nil

  @due_batch 100
  @panel [:operator, :installation_operator]
  @text_fields ["/name", "/description"]

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
  # WF-4
  @spec replace_draft(Scope.t(), String.t(), Definition.t(), pos_integer() | nil, Actor.t()) ::
          {:ok,
           {:replaced | :unchanged | :version_conflict | :not_found | :managed_by_code, term()}}
  def replace_draft(%Scope{} = scope, key, definition, expected_version, %Actor{} = actor) do
    case manager_rule(key, definition, actor) do
      :ok ->
        attrs = Map.put(attrs(definition), :draft_id, Relay.Id.generate())
        digest = digest(scope, "workflow.drafted", key)
        {:ok, Store.draft_put(key, attrs, expected_version, digest, actor)}

      {:error, pointers} ->
        {:ok, {:managed_by_code, pointers}}
    end
  end

  # WF-4
  # X-9
  defp manager_rule(key, definition, %Actor{kind: kind}) when kind in @panel do
    with %{"managed_by" => "code"} = workflow <- Store.get(key),
         %{"definition" => base} <- base_definition(workflow) do
      allowed = MapSet.new(@text_fields ++ (base["controls"] || []))

      case Enum.reject(changes(base, definition, ""), &MapSet.member?(allowed, &1)) do
        [] -> :ok
        pointers -> {:error, pointers}
      end
    else
      _panel_or_new -> :ok
    end
  end

  defp manager_rule(_key, _definition, _actor), do: :ok

  defp base_definition(workflow) do
    Store.draft(workflow["id"]) ||
      Store.published_version(workflow["id"], workflow["published_version_no"])
  end

  defp changes(same, same, _pointer), do: []

  defp changes(%{} = old, %{} = new, pointer) do
    if Enum.sort(Map.keys(old)) == Enum.sort(Map.keys(new)),
      do: Enum.flat_map(old, fn {k, v} -> changes(v, new[k], pointer <> "/" <> escape(k)) end),
      else: ["!" <> pointer]
  end

  defp changes(old, new, pointer)
       when is_list(old) and is_list(new) and length(old) == length(new) do
    old
    |> Enum.zip(new)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{a, b}, index} -> changes(a, b, pointer <> "/#{index}") end)
  end

  defp changes(old, new, pointer) when is_binary(old) and is_binary(new), do: [pointer]
  defp changes(old, new, pointer) when is_number(old) and is_number(new), do: [pointer]
  defp changes(_old, _new, pointer), do: ["!" <> pointer]

  defp escape(key), do: key |> String.replace("~", "~0") |> String.replace("/", "~1")

  # WF-4
  # X-9
  @doc "Changes the single manager of a workflow (`panel` or `code`) inside the caller's scoped transaction; audited as `workflow.manager_changed`."
  @spec set_manager(Scope.t(), String.t(), String.t(), pos_integer() | nil, Actor.t()) ::
          {:ok, {:changed | :unchanged | :version_conflict | :not_found, pos_integer() | nil}}
  def set_manager(%Scope{} = scope, key, managed_by, expected_version, %Actor{} = actor)
      when managed_by in ["panel", "code"] do
    digest = digest(scope, "workflow.manager_changed", key <> ":" <> managed_by)
    {:ok, RunStore.manager_set(key, managed_by, expected_version, digest, actor)}
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

  # WF-6
  @doc "A published version as a Mermaid flowchart; `{:ok, :workflow_not_found}` or `{:ok, :version_not_found}` when missing."
  @spec mermaid(Scope.t(), String.t(), pos_integer()) ::
          result(String.t() | :workflow_not_found | :version_not_found)
  def mermaid(%Scope{} = scope, key, version_no) do
    case get_version(scope, key, version_no) do
      {:ok, %{"definition" => definition}} -> {:ok, Definition.mermaid(definition)}
      other -> other
    end
  end

  # WF-60
  # AG-14
  @doc "Checks a condition of the workflow condition language; see `Relay.Workflow.Condition.validate/2`. A waitpoint's second-stage `match` passes `incoming: true`."
  @spec validate_condition(term(), Condition.scope()) :: [Condition.field_error()]
  defdelegate validate_condition(condition, scope), to: Condition, as: :validate

  # WF-60
  # AG-14
  @doc "Decides a condition against a context; see `Relay.Workflow.Condition.evaluate/2`."
  @spec evaluate_condition(Condition.t(), Condition.context()) :: boolean()
  defdelegate evaluate_condition(condition, context), to: Condition, as: :evaluate

  # WF-59 (5)
  # WF-41
  # WF-43
  @doc """
  Creates the run of a new notification inside the caller's accepting transaction and advances it up to its first waiting step. `run` carries `:notification_id`, the pinned `:definition`, the `:plan` the resumer needs later (JSON, no personal data), the step `:context` (`t:Relay.Workflow.Step.context/0` without `:results` and `:outcomes`), `:now` (the business time base: `send_at` when the request has one) and the `:opener` of channel steps. Returns the openers' extras in step order.
  """
  @spec start_run(Scope.t(), map()) :: {:ok, [term()]} | {:error, term()}
  def start_run(%Scope{} = scope, run) do
    context = Map.put(run.context, :outcomes, &outcomes/1)

    with {:ok, outcome} <-
           Runner.advance(run.definition, Runner.new(), context, run.now, run.opener) do
      fields = fields(outcome)

      attrs =
        Map.merge(fields, %{
          id: Relay.Id.generate(),
          notification_id: run.notification_id,
          plan: run.plan,
          started_at: run.now
        })

      case RunStore.start(attrs) do
        {:started, id} ->
          :ok = timer(scope, id, fields.wake_at)
          {:ok, fields.extras}

        {other, _id} ->
          {:error, other}
      end
    end
  end

  # WF-43
  # WF-6
  @doc "Advances a waiting run whose wake time has come, in its own transaction; a run that is not due yet gets its timer again. Returns `:waiting`, `:completed`, `:not_due`, `:final`, `:raced` or `:not_found`."
  @spec wake(Scope.t(), Relay.Id.t()) :: result(atom())
  def wake(%Scope{} = scope, run_id) do
    now = Relay.Clock.business_now(scope)

    case RunStore.in_scope(scope, fn _status -> RunStore.get(run_id) end) do
      {:ok, nil} -> {:ok, :not_found}
      {:ok, %{"state" => "waiting"} = run} -> due(scope, run, now)
      {:ok, _final} -> {:ok, :final}
      {:error, _reason} = error -> error
    end
  end

  defp due(scope, run, now) do
    if DateTime.compare(run["wake_at"], now) == :gt do
      RunStore.in_scope(scope, fn _status ->
        :ok = timer(scope, run["id"], run["wake_at"])
        :not_due
      end)
    else
      resume(scope, run, now)
    end
  end

  defp resume(scope, %{"notification_state" => state} = run, _now) when state != "active" do
    rule = if state == "expired", do: "expiry.expires_at", else: "cancel.request"

    RunStore.in_scope(scope, fn _status ->
      :locked = RunStore.lock(run["id"])

      stopped = %{
        cursor: run["step_cursor"],
        results: run["step_results"],
        state: "completed",
        wake_at: nil,
        outcome: "stopped",
        rule_id: rule
      }

      saved(RunStore.save(run["id"], run["version"], stopped), :completed)
    end)
  end

  defp resume(scope, run, now) do
    with {:ok, bind} <- resumer().resume(scope, run) do
      RunStore.in_scope(scope, fn _status ->
        :locked = RunStore.lock(run["id"])

        expected = run["version"]

        case RunStore.get(run["id"]) do
          %{"state" => "waiting", "version" => ^expected} ->
            advance(scope, run, now, bind)

          _changed ->
            :raced
        end
      end)
    end
  end

  defp advance(scope, run, now, bind) do
    state = %{"cursor" => run["step_cursor"], "results" => run["step_results"]}

    with {:ok, context, opener} <- bind.(),
         context = Map.put(context, :outcomes, &outcomes/1),
         {:ok, outcome} <- Runner.advance(run["definition"], state, context, now, opener) do
      fields = fields(outcome)
      :ok = timer(scope, run["id"], fields.wake_at)
      saved(RunStore.save(run["id"], run["version"], fields), state_atom(fields.state))
    else
      {:error, reason} -> RunStore.rollback(reason)
    end
  end

  defp state_atom("waiting"), do: :waiting
  defp state_atom("completed"), do: :completed

  defp saved({:saved, _version}, result), do: result
  defp saved({other, _version}, _result), do: RunStore.rollback(other)

  defp resumer, do: :relay |> Application.fetch_env!(__MODULE__) |> Keyword.fetch!(:resumer)

  defp fields({:waiting, at, state, extras}) do
    %{
      cursor: state["cursor"],
      results: state["results"],
      state: "waiting",
      wake_at: at,
      outcome: nil,
      rule_id: nil,
      extras: extras
    }
  end

  defp fields({:completed, outcome, rule_id, state, extras}) do
    %{
      cursor: state["cursor"],
      results: state["results"],
      state: "completed",
      wake_at: nil,
      outcome: outcome,
      rule_id: rule_id,
      extras: extras
    }
  end

  # WF-60
  defp outcomes(results) do
    ids = for text <- Runner.delivery_ids(results), {:ok, id} <- [Relay.Id.parse(text)], do: id

    deliveries =
      for {id, row} <- RunStore.deliveries(ids), into: %{}, do: {Relay.Id.to_string(id), row}

    Runner.outcomes(results, deliveries)
  end

  # T-24
  # WF-43
  defp timer(_scope, _run_id, nil), do: :ok

  defp timer(scope, run_id, %DateTime{} = at) do
    args = scope |> Scope.to_job_args() |> Map.put("run_id", Relay.Id.to_string(run_id))
    Store.insert_job!(RunTimer.new(args, scheduled_at: Relay.Clock.wall_time(scope, at)))
  end

  # WF-43
  # TN-8
  @doc "Wakes every run of a scope whose wake time has come in business time; used by the missed-timer sweep and the virtual clock tick."
  @spec run_due(Scope.t()) :: :ok | {:error, term()}
  def run_due(%Scope{} = scope) do
    case RunStore.in_scope(scope, fn _status -> RunStore.due(@due_batch) end) do
      {:ok, due} ->
        Enum.each(due, fn {id, _wake_at} -> wake(scope, id) end)
        if length(due) == @due_batch, do: run_due(scope), else: :ok

      {:error, _reason} = error ->
        error
    end
  end

  # WF-43
  @doc "Wakes the due runs of every scope that has one; returns how many scopes were visited."
  @spec sweep(pos_integer()) :: non_neg_integer()
  def sweep(limit \\ 100) do
    limit
    |> RunStore.due_scopes()
    |> Enum.count(fn {tenant_id, environment} ->
      with {:ok, scope} <- Scope.new(tenant_id, environment),
           :ok <- run_due(scope) do
        true
      else
        _failed -> false
      end
    end)
  end

  # API-57
  # API-58
  @doc "Cancels the running and waiting runs of an event (`:event_id`), a notification (`:notification_id`) or a cancellation key (`:cancellation_key`, optionally with `:recipient_ids`) inside the caller's scoped transaction; returns how many."
  @spec cancel_runs(map()) :: non_neg_integer()
  defdelegate cancel_runs(filter), to: RunStore, as: :cancel

  # WF-59 (5)
  @doc "Reads the run of a notification with its state, cursor and step results; `nil` when there is none."
  @spec run(Scope.t(), Relay.Id.t()) :: result(map() | nil)
  def run(%Scope{} = scope, notification_id),
    do: RunStore.in_scope(scope, fn _status -> RunStore.by_notification(notification_id) end)

  # WF-59
  @doc "Every step of a definition's tree in order with its RFC 6901 pointer under `/definition`."
  @spec step_entries(Definition.t()) :: [{map(), String.t()}]
  def step_entries(definition) do
    for %{step: step, pointer: pointer} <- Definition.entries(definition), do: {step, pointer}
  end

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
