defmodule Relay.Workflow do
  @moduledoc """
  Workflows, steps, routing, escalation and scheduling. Other contexts use only the functions of this module.

  A workflow is a registry entry with immutable versions (WF-5): a draft is replaced as a whole, a publication request moves it to the publication gate (`Relay.Workflow.PublishGate`, `Relay.Workflow.Definition.gate/1`), and a published version never changes (INV-48). Going back to an old version publishes its definition again as a new version (WF-6), and a published version exports as a Mermaid flowchart. A definition is data (C-40, WF-59): its event schema, its message class and category, and its step tree; nothing in it runs as customer code.

  Every workflow has one manager, `panel` or `code` (WF-4): a draft written through the panel (an operator actor) to a code-managed workflow may change only its text fields and the fields its definition lists in `controls`; changing the manager is an explicit, audited action (`set_manager/5`).

  Every notification of a workflow has one run (WF-59 (5), `Relay.Workflow.Runner`): `start_run/2` creates it at acceptance, in the accepting transaction, and advances it synchronously up to the first waiting step, opening the deliveries of the channel steps it reaches through the caller's opener. A waiting run is a row and one timer job (`Relay.Workflow.RunTimer`, WF-43); `wake/2` advances it later in its own transaction, with the opener of the configured resumer (`config :relay, Relay.Workflow, resumer: Module`, a module with `resume/2` that, outside any transaction, returns a function giving the step context and the opener inside the run's transaction). The missed-timer sweep (`Relay.Workflow.RunSweep`) wakes due runs whose timer job is missing. A run finishes on the version it started (WF-6). Cancelling an event, a notification or a cancellation key cancels its runs (`cancel_runs/1`).

  Named routes (WF-13, WF-14) are unversioned `{key, name, tree}` records: a change applies to every new decision, and a category may name one as its default. `Relay.Workflow.Route` resolves the tree of a channel step and evaluates it.

  Recurrence rules (`Relay.Workflow.Recurrence`, C-52, WF-48, WF-49) are definitions of one workflow sent to a subscriber or a topic on the occurrences of an RRULE subset (`Relay.Workflow.RRule`, WF-61); the rule's next occurrence is a row column with a timer, never a waiting message (WF-43).
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Actor
  alias Relay.Scope
  alias Relay.Workflow.Condition
  alias Relay.Workflow.ContentDedup
  alias Relay.Workflow.Definition
  alias Relay.Workflow.Digest
  alias Relay.Workflow.KeyTemplate
  alias Relay.Workflow.PublishGate
  alias Relay.Workflow.Recurrence
  alias Relay.Workflow.RecurrenceStore
  alias Relay.Workflow.Route
  alias Relay.Workflow.RouteStore
  alias Relay.Workflow.RouteTree
  alias Relay.Workflow.Runner
  alias Relay.Workflow.RunStore
  alias Relay.Workflow.RunTimer
  alias Relay.Workflow.Store
  alias Relay.Workflow.Throttle

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
          errors = Definition.gate(definition) ++ named_routes(definition)
          {outcome, errors} = gate_outcome(errors)
          digest = digest(scope, "workflow.published", Relay.Id.to_string(version_id))
          Store.publish_complete(version_id, outcome, errors, digest, @gate)

        _other ->
          {:not_pending, nil}
      end
    end)
  end

  # WF-14
  # WF-18
  defp named_routes(definition) do
    routes =
      for {step, _pointer} <- step_entries(definition),
          step["type"] == "channel",
          key = step["route"],
          is_binary(key),
          into: %{},
          do: {key, route_channels(RouteStore.get(key))}

    Definition.named_route_errors(definition, routes)
  end

  defp route_channels(%{"state" => "active", "tree" => tree}), do: RouteTree.channels(tree)
  defp route_channels(_missing_or_archived), do: nil

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
      {:ok, %{} = version} -> {:ok, Definition.mermaid(version["definition"])}
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

  # WF-14
  # WF-7
  @doc "Resolves the route tree of every channel step of a definition in its own read transaction (WF-14): a map of step key to `tree`, or to `skip` with the rule of a route that does not resolve. The run copies the result into the notification's plan, so a later change to a named route does not change it (WF-7)."
  @spec prepare_routes(Scope.t(), Definition.t()) :: result(%{String.t() => map()})
  def prepare_routes(%Scope{} = scope, definition) do
    Store.in_scope(scope, fn _status -> routes(definition) end)
  end

  # WF-14
  @doc "Resolves the route trees of a definition's channel steps inside the caller's scoped transaction; see `prepare_routes/2`."
  @spec routes(Definition.t()) :: %{String.t() => map()}
  def routes(definition) do
    for %{step: %{"type" => "channel"} = step} <- Definition.entries(definition), into: %{} do
      case Route.resolve(step, definition["category"]) do
        {:ok, tree, _source} -> {step["key"], %{"tree" => tree}}
        {:skip, rule_id} -> {step["key"], %{"skip" => rule_id}}
      end
    end
  end

  # WF-13
  # WF-8
  @doc "The channel steps of a definition with their resolved routes, one entry per channel a step's tree names: `{key, channel, template, digest_template}`."
  @spec route_steps(Definition.t(), %{String.t() => map()}) :: [map()]
  def route_steps(definition, routes) do
    for %{step: %{"type" => "channel"} = step} <- Definition.entries(definition),
        %{"tree" => tree} <- [Map.get(routes, step["key"])],
        channel <- RouteTree.channels(tree),
        do: %{
          key: step["key"],
          channel: channel,
          template: step["template"],
          digest_template: step["digest_template"]
        }
  end

  # WF-59 (5)
  # WF-41
  # WF-43
  @doc """
  Creates the run of a new notification inside the caller's accepting transaction and advances it up to its first wait. `run` carries `:notification_id`, `:recipient_id`, `:workflow_key`, `:message_class`, the pinned `:definition`, the `:plan` the resumer needs later (JSON, no personal data, with the resolved `routes`), the step `:context` (`t:Relay.Workflow.Step.context/0` with the plan's `:routes` and the `:facts` of a step's route, without `:results`, `:outcomes`, `:projection` and `:effects`), `:now` (the business time base: `send_at` when the request has one) and the `:opener` of route leaves. Returns the openers' extras in step order.
  """
  @spec start_run(Scope.t(), map()) :: {:ok, [term()]} | {:error, term()}
  def start_run(%Scope{} = scope, run) do
    context = with_effects(scope, run.context, run)

    with {:ok, outcome} <-
           Runner.advance(run.definition, Runner.new(), context, run.now, run.opener) do
      attrs =
        Map.merge(fields(outcome), %{
          id: Relay.Id.generate(),
          notification_id: run.notification_id,
          plan: run.plan,
          started_at: run.now
        })

      case RunStore.start(attrs) do
        {:started, id} ->
          :ok = timer(scope, id, outcome.wake_at)
          {:ok, outcome.extras}

        {other, _id} ->
          {:error, other}
      end
    end
  end

  defp with_effects(scope, context, meta) do
    Map.merge(context, %{
      outcomes: &outcomes/1,
      projection: &projection/1,
      effects: %{
        digest: &digest_effect(scope, context, meta, &1),
        throttle: &throttle_effect(scope, context, meta, &1)
      }
    })
  end

  # WF-26
  # WF-27
  defp digest_effect(scope, context, meta, step) do
    Digest.add(scope, %{
      recipient_id: meta.recipient_id,
      notification_id: meta.notification_id,
      message_class: meta.message_class,
      scope_ref: "#{meta.workflow_key}:#{step["key"]}",
      key: KeyTemplate.render(step["digest_key"], context),
      step: step,
      time_zone: context.time_zone,
      origin: "step"
    })
  end

  # WF-32
  defp throttle_effect(scope, context, meta, step) do
    fields = Map.put(step, "key", step["throttle_key"])

    attrs = %{
      key: KeyTemplate.render(step["throttle_key"], context),
      ref: "#{Relay.Id.to_string(meta.notification_id)}:#{step["key"]}",
      time_zone: context.time_zone,
      until: until(step["until"], context.data)
    }

    Throttle.hit(scope, fields, attrs)
  end

  defp until(nil, _data), do: nil

  defp until(pointer, data) do
    segments = pointer |> String.split("/") |> tl()

    with {:ok, text} when is_binary(text) <- Definition.get(data, segments),
         {:ok, at, _offset} <- DateTime.from_iso8601(text) do
      at
    else
      _missing -> nil
    end
  end

  # WF-43
  # WF-6
  @doc "Advances a run in its own transaction: a waiting run whose wake time has come, or with `force: true` (a delivery of one of its routes settled, a digest window fired) any running or waiting run; a waiting run that is not due gets its timer again. Returns `:waiting`, `:running`, `:completed`, `:not_due`, `:final`, `:raced` or `:not_found`."
  @spec wake(Scope.t(), Relay.Id.t(), boolean()) :: result(atom())
  def wake(%Scope{} = scope, run_id, force \\ false) do
    now = Relay.Clock.business_now(scope)

    case RunStore.in_scope(scope, fn _status -> RunStore.get(run_id) end) do
      {:ok, nil} ->
        {:ok, :not_found}

      {:ok, %{"state" => state} = run} when state in ["waiting", "running"] ->
        due(scope, run, now, force)

      {:ok, _final} ->
        {:ok, :final}

      {:error, _reason} = error ->
        error
    end
  end

  defp due(scope, %{"state" => "waiting"} = run, now, false) do
    if DateTime.compare(run["wake_at"], now) == :gt do
      RunStore.in_scope(scope, fn _status ->
        :ok = timer(scope, run["id"], run["wake_at"])
        :not_due
      end)
    else
      resume(scope, run, now)
    end
  end

  defp due(scope, %{"state" => "running"} = run, now, false), do: resume(scope, run, now)
  defp due(scope, run, now, true), do: resume(scope, run, now)

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
      RunStore.in_scope(scope, fn _status -> locked(scope, run, now, bind) end)
    end
  end

  defp locked(scope, run, now, bind) do
    :locked = RunStore.lock(run["id"])
    expected = run["version"]

    case RunStore.get(run["id"]) do
      %{"state" => state, "version" => ^expected} = current
      when state in ["waiting", "running"] ->
        advance(scope, current, now, bind)

      _changed ->
        :raced
    end
  end

  defp advance(scope, run, now, bind) do
    state = Map.put(run["step_cursor"], "results", run["step_results"])
    meta = meta(run)

    with {:ok, context, opener} <- bind.(),
         context = with_effects(scope, context, meta),
         {:ok, outcome} <- Runner.advance(run["definition"], state, context, now, opener) do
      fields = fields(outcome)
      :ok = timer(scope, run["id"], outcome.wake_at)
      saved(RunStore.save(run["id"], run["version"], fields), state_atom(outcome.status))
    else
      {:error, reason} -> RunStore.rollback(reason)
    end
  end

  defp meta(run) do
    %{
      recipient_id: run["recipient_id"],
      notification_id: run["notification_id"],
      message_class: run["message_class"],
      workflow_key: run["workflow_key"]
    }
  end

  defp state_atom("waiting"), do: :waiting
  defp state_atom("running"), do: :running
  defp state_atom("completed"), do: :completed

  defp saved({:saved, _version}, result), do: result
  defp saved({other, _version}, _result), do: RunStore.rollback(other)

  defp resumer, do: :relay |> Application.fetch_env!(__MODULE__) |> Keyword.fetch!(:resumer)

  defp fields(outcome) do
    state = outcome.state

    %{
      cursor: Map.delete(state, "results"),
      results: state["results"],
      state: outcome.status,
      wake_at: outcome.wake_at,
      outcome: outcome.outcome,
      rule_id: outcome.rule_id
    }
  end

  # WF-60
  defp outcomes(results) do
    Runner.outcomes(results, projection(Runner.delivery_ids(results)))
  end

  defp projection(texts) do
    ids = for text <- texts, {:ok, id} <- [Relay.Id.parse(text)], do: id
    for {id, row} <- RunStore.deliveries(ids), into: %{}, do: {Relay.Id.to_string(id), row}
  end

  # T-24
  # WF-43
  defp timer(scope, run_id, at, force \\ false)

  defp timer(_scope, _run_id, nil, false), do: :ok

  defp timer(scope, run_id, at, force) do
    args =
      scope
      |> Scope.to_job_args()
      |> Map.put("run_id", Relay.Id.to_string(run_id))
      |> then(&if(force, do: Map.put(&1, "force", true), else: &1))

    opts = if at, do: [scheduled_at: Relay.Clock.wall_time(scope, at)], else: []
    Store.insert_job!(RunTimer.new(args, opts))
  end

  # WF-13
  # WF-15
  @doc "The settled step of the delivery job, configured as `config :relay, Relay.Delivery, settled: Module`: when a delivery's job run ends, the run of its notification evaluates its routes again through a forced timer job, so a fallback moves on a permanent failure (WF-15). Runs in its own transaction."
  @spec delivery_settled(Scope.t(), Relay.Id.t()) :: :ok | {:error, term()}
  def delivery_settled(%Scope{} = scope, delivery_id) do
    result =
      RunStore.in_scope(scope, fn _status ->
        case RunStore.routing_run(delivery_id) do
          nil -> :ok
          run_id -> timer(scope, run_id, nil, true)
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # WF-27
  # INV-3
  @doc "The digest sink (`config :relay, Relay.Workflow.Digest, sink: Relay.Workflow`): inside the window's closing transaction, resumes the parked run of the anchor notification with the digest render data (`digest`) or the singular path (`single`) through a forced timer job, or ends it when the recipient read the activities first (`cancelled`)."
  @spec digest_ready(Scope.t(), Digest.Sink.outcome()) :: :ok
  def digest_ready(%Scope{} = scope, {kind, info}) do
    case info.notification_id && RunStore.by_notification(info.notification_id) do
      %{"step_cursor" => %{"parked" => key}} = run when is_binary(key) ->
        unpark(scope, run, kind, info)

      _none ->
        :ok
    end
  end

  defp unpark(_scope, run, :cancelled, _info) do
    state = Map.put(run["step_cursor"], "parked", nil)

    fields = %{
      cursor: state,
      results: run["step_results"],
      state: "completed",
      wake_at: nil,
      outcome: "completed",
      rule_id: nil
    }

    {:saved, _version} = RunStore.save(run["id"], run["version"], fields)
    :ok
  end

  defp unpark(scope, run, kind, info) do
    state =
      Runner.unpark(
        Map.put(run["step_cursor"], "results", run["step_results"]),
        Atom.to_string(kind),
        Map.get(info, :render)
      )

    fields = %{
      cursor: Map.delete(state, "results"),
      results: state["results"],
      state: "running",
      wake_at: nil,
      outcome: nil,
      rule_id: nil
    }

    {:saved, _version} = RunStore.save(run["id"], run["version"], fields)
    timer(scope, run["id"], nil, true)
  end

  # WF-29
  @doc "The digest render data of a delivery that a run opened with its step's `digest_template` after a window of two or more activities fired, inside the caller's scoped transaction; `nil` for any other delivery."
  @spec digest_render(Relay.Id.t()) :: map() | nil
  def digest_render(delivery_id) do
    with %{"step_cursor" => %{"digest" => %{"kind" => "digest", "step" => key}}} = run <-
           RunStore.by_delivery(delivery_id),
         id = Relay.Id.to_string(delivery_id),
         true <-
           Enum.any?(run["step_results"], fn {_key, result} ->
             result["digest"] == true and id in (result["deliveries"] || [])
           end) do
      run["step_results"][key]["render"]
    else
      _none -> nil
    end
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

  # WF-13
  # WF-59 (4)
  @doc "Creates a named route inside the caller's scoped transaction."
  @spec create_route(Scope.t(), String.t(), String.t(), Route.tree(), Actor.t()) ::
          {:created | :key_conflict | :tenant_inactive, Relay.Id.t() | nil, version()}
  def create_route(%Scope{} = scope, key, name, tree, %Actor{} = actor) do
    attrs = %{id: Relay.Id.generate(), key: key, name: name, tree: tree}
    RouteStore.create(attrs, digest(scope, "route.created", key), actor)
  end

  # WF-14
  @doc "Replaces the name and tree of a route inside the caller's scoped transaction; `expected_version` is the route's ETag version. The change applies to every decision made after it."
  @spec replace_route(Scope.t(), String.t(), String.t(), Route.tree(), version(), Actor.t()) ::
          {:replaced | :unchanged | :not_found | :archived | :version_conflict, version()}
  def replace_route(%Scope{} = scope, key, name, tree, expected_version, %Actor{} = actor) do
    digest = digest(scope, "route.replaced", key)
    RouteStore.replace(key, %{name: name, tree: tree}, expected_version, digest, actor)
  end

  # WF-14
  @doc "Archives a route inside the caller's scoped transaction; a route that an active category names as its default is `:in_use`."
  @spec archive_route(Scope.t(), String.t(), Actor.t()) ::
          {:archived | :already_archived | :in_use | :not_found, version()}
  def archive_route(%Scope{} = scope, key, %Actor{} = actor),
    do: RouteStore.archive(key, digest(scope, "route.archived", key), actor)

  # WF-13
  @doc "Reads a route by key in its own read transaction; `nil` when the key is unknown."
  @spec get_route(Scope.t(), String.t()) :: result(map() | nil)
  def get_route(%Scope{} = scope, key),
    do: Store.in_scope(scope, fn _status -> RouteStore.get(key) end)

  # WF-13
  @doc "Reads a route by key inside the caller's scoped transaction; `nil` when the key is unknown."
  @spec route(String.t()) :: map() | nil
  defdelegate route(key), to: RouteStore, as: :get

  # API-56
  @doc "Lists routes newest first from a decoded cursor; at most `limit + 1` rows come back."
  @spec list_routes(Scope.t(), map() | nil, pos_integer()) :: result([map()])
  def list_routes(%Scope{} = scope, cursor, limit),
    do: Store.in_scope(scope, fn _status -> RouteStore.list(cursor, limit) end)

  # WF-14
  @doc "Resolves the tree of a channel step inside the caller's scoped transaction; see `Relay.Workflow.Route.resolve/2`."
  @spec resolve_route(map(), String.t() | nil) ::
          {:ok, Route.tree(), Route.source()} | {:skip, String.t()}
  defdelegate resolve_route(step, category_key), to: Route, as: :resolve

  # WF-13
  # WF-15
  # WF-21
  @doc "The next actions of a resolved route tree; see `Relay.Workflow.RouteTree.next/3`."
  @spec next_route(Route.tree(), map(), map()) :: {:ok, map()} | {:error, [map()]}
  defdelegate next_route(tree, facts, state), to: Route, as: :next

  # WF-15
  # WF-18
  # WF-59 (4)
  @doc "Validates a route tree; see `Relay.Workflow.RouteTree.validate/2`."
  @spec validate_route(term(), keyword()) :: :ok | {:error, [map()]}
  defdelegate validate_route(tree, opts \\ []), to: Route, as: :validate

  # WF-48
  # WF-61
  @doc "Checks a new recurrence rule and computes its first occurrence and timer in its own read transaction; see `Relay.Workflow.Recurrence.plan/2`."
  @spec plan_recurrence(Scope.t(), Recurrence.input()) ::
          {:ok, Recurrence.planned()} | {:error, Relay.Error.t()}
  def plan_recurrence(%Scope{} = scope, input) do
    case RecurrenceStore.in_scope(scope, fn _status -> Recurrence.plan(scope, input) end) do
      {:ok, result} -> result
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # WF-49
  # WF-61
  @doc "Records a planned recurrence rule inside the caller's scoped transaction; `:limit_reached` when the tenant environment already holds the most active rules."
  @spec create_recurrence(map(), <<_::256>>, Actor.t()) :: :created | :limit_reached
  def create_recurrence(attrs, digest, %Actor{} = actor),
    do: RecurrenceStore.create(attrs, Recurrence.max_active(), digest, actor)

  # WF-49
  @doc "Cancels an active recurrence rule inside the caller's scoped transaction."
  @spec cancel_recurrence(Relay.Id.t(), String.t(), <<_::256>>, Actor.t()) ::
          :cancelled | :closed | :not_found
  def cancel_recurrence(id, reason, digest, %Actor{} = actor),
    do: RecurrenceStore.cancel(id, reason, digest, actor)

  # WF-49
  # OP-24
  @doc "Cancels an active recurrence rule in its own transaction, as a timer does for a subscriber that was erased."
  @spec cancel_recurrence(Scope.t(), Relay.Id.t(), String.t(), <<_::256>>, Actor.t()) ::
          result(:cancelled | :closed | :not_found)
  def cancel_recurrence(%Scope{} = scope, id, reason, digest, %Actor{} = actor) do
    RecurrenceStore.in_scope(scope, fn _status ->
      RecurrenceStore.cancel(id, reason, digest, actor)
    end)
  end

  # WF-48
  @doc "Reads a recurrence rule with its last occurrence inside the caller's scoped transaction, or `nil`."
  @spec view_recurrence(Relay.Id.t()) :: map() | nil
  def view_recurrence(id) do
    case RecurrenceStore.get(id) do
      nil -> nil
      row -> hd(with_last([row]))
    end
  end

  # WF-48
  @doc "Reads a recurrence rule with its last occurrence in its own read transaction, or `nil`."
  @spec get_recurrence(Scope.t(), Relay.Id.t()) :: result(map() | nil)
  def get_recurrence(%Scope{} = scope, id),
    do: RecurrenceStore.in_scope(scope, fn _status -> view_recurrence(id) end)

  # API-56
  @doc "Lists recurrence rules newest first from a decoded cursor, each with its last occurrence; at most `limit + 1` rows come back."
  @spec list_recurrences(Scope.t(), map() | nil, pos_integer()) :: result([map()])
  def list_recurrences(%Scope{} = scope, cursor, limit) do
    RecurrenceStore.in_scope(scope, fn _status ->
      with_last(RecurrenceStore.page(cursor, limit))
    end)
  end

  # WF-61
  @doc "The recorded occurrences of a recurrence rule, oldest first, at most `limit`, in its own read transaction."
  @spec recurrence_occurrences(Scope.t(), Relay.Id.t(), pos_integer()) :: result([map()])
  def recurrence_occurrences(%Scope{} = scope, id, limit),
    do: RecurrenceStore.in_scope(scope, fn _status -> RecurrenceStore.occurrences(id, limit) end)

  # WF-49
  # WF-61
  @doc "Works out what a recurrence rule has due at `now` in its own read transaction; see `Relay.Workflow.Recurrence.due/3`."
  @spec due_recurrence(Scope.t(), Relay.Id.t(), DateTime.t()) ::
          {:ok, Recurrence.due()} | {:error, Relay.Error.t()}
  def due_recurrence(%Scope{} = scope, id, now) do
    case RecurrenceStore.in_scope(scope, fn _status -> Recurrence.due(scope, id, now) end) do
      {:ok, {:error, %Relay.Error{}} = error} -> error
      {:ok, due} -> {:ok, due}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # WF-49
  # WF-61
  @doc "Records the occurrences of a recurrence rule and moves it to its next occurrence inside the caller's scoped transaction; see `Relay.Workflow.RecurrenceStore.fire/4`."
  @spec fire_recurrence(Relay.Id.t(), DateTime.t(), [map()], Recurrence.next() | nil) ::
          :advanced | :completed | :stale | :not_found
  defdelegate fire_recurrence(id, expected_next_at, occurrences, next),
    to: RecurrenceStore,
    as: :fire

  # WF-49
  # WF-61
  @doc "Records the occurrences of a recurrence rule and moves it to its next occurrence in its own transaction; `job` builds the timer job of the next occurrence, queued in the same transaction."
  @spec record_recurrence(
          Scope.t(),
          Relay.Id.t(),
          DateTime.t(),
          [map()],
          Recurrence.next() | nil,
          (Recurrence.next() -> Ecto.Changeset.t())
        ) :: result(:advanced | :completed | :stale | :not_found)
  def record_recurrence(%Scope{} = scope, id, expected_next_at, occurrences, next, job) do
    RecurrenceStore.in_scope(scope, fn _status ->
      result = RecurrenceStore.fire(id, expected_next_at, occurrences, next)
      if result == :advanced, do: RecurrenceStore.insert_job!(job.(next))
      result
    end)
  end

  # WF-43
  @doc "The identifiers of the active recurrence rules of a scope whose timer is due at `now`, in its own read transaction."
  @spec due_recurrences(Scope.t(), DateTime.t(), pos_integer()) :: result([Relay.Id.t()])
  def due_recurrences(%Scope{} = scope, now, limit),
    do: RecurrenceStore.in_scope(scope, fn _status -> RecurrenceStore.due(now, limit) end)

  # WF-43
  @doc "The scopes with a recurrence timer due at least `min_age_ms` ago; see `Relay.Workflow.RecurrenceStore.due_scopes/2`."
  @spec recurrence_due_scopes(non_neg_integer(), pos_integer()) :: [{Relay.Id.t(), String.t()}]
  defdelegate recurrence_due_scopes(min_age_ms, limit), to: RecurrenceStore, as: :due_scopes

  # WF-42
  # WF-58
  @doc "The timer instant of an occurrence; see `Relay.Workflow.Recurrence.fire_at/3`."
  @spec recurrence_fire_at(Scope.t(), Relay.Id.t(), DateTime.t()) :: DateTime.t()
  defdelegate recurrence_fire_at(scope, id, at), to: Recurrence, as: :fire_at

  @doc "The UTC text of an occurrence instant; see `Relay.Workflow.Recurrence.iso/1`."
  @spec recurrence_instant(DateTime.t()) :: String.t()
  defdelegate recurrence_instant(at), to: Recurrence, as: :iso

  @doc "Queues a job inside the caller's scoped transaction; rolls the transaction back when it is not queued."
  @spec queue_job!(Ecto.Changeset.t()) :: :ok
  defdelegate queue_job!(changeset), to: RecurrenceStore, as: :insert_job!

  defp with_last(rows) do
    last = RecurrenceStore.last_occurrences(Enum.map(rows, & &1["id"]))
    Enum.map(rows, &Map.put(&1, "last_occurrence", Map.get(last, &1["id"])))
  end

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})

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
