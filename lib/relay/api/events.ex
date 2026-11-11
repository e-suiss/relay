defmodule Relay.Api.Events do
  @moduledoc """
  The send operations (API-19 … API-34, OP-7, DS-36). An event is prepared outside any transaction (`prepare/3`): its workflow version is resolved and frozen (WF-7), the request's field rules and the event schema are checked (API-20, API-27), the recipients' writes are prepared with their keys (API-21) and the payload is sealed under the tenant data key. It is then accepted inside the request's idempotency transaction (`accept/2`), so the idempotency claim, the event, its notifications and deliveries with their opening ledger events, the queue jobs, the quota counters and the outbox events commit together or not at all.

  Every notification has one workflow run (WF-59 (5), `Relay.Workflow.start_run/2`): at acceptance the run is created and advanced in the same transaction up to its first waiting step, and each channel step it reaches opens its delivery here (`open_step/6`), exactly as a workflow of channel steps alone always did; a later step opens its delivery when the run wakes (`Relay.Api.WorkflowRuns`). A request's `send_at` is the run's time base (WF-41).

  Policy outcomes are decisions, not errors (C-4, MD-12, DS-26): every delivery is opened and the policy lattice decides it at once (`Relay.Policy.Live`, PC-58 (2)): a gate or filter skips it, a shaper defers it to `deferred_until` and queues its job for then, and an expiry closes it, each recorded with its reason, rule and detail and announced as `notification.suppressed` (DS-24, DS-27). The class comes from the workflow's category (PC-57 (3)), the priority is clamped to the class ceiling with a `priority_clamped` warning (API-22, PC-58 (7)) and a request without `expires_at` gets the category's or the class default (PC-57 (4)). A matching kill switch pauses the delivery at acceptance and queues no job (TN-40), the send mode `off` and an unknown sub-tenant skip it with a rule (OP-51, API-25), and a suspended subscriber's deliveries are skipped with `subscriber.suspended` (TN-73): the send is accepted and no delivery is sent. Before the lattice, each delivery's template is resolved with sub-tenant inheritance and its cell chosen for the recipient's locale (`Relay.Templates.Live`): a channel without a variant, a locale chain without a cell and a template without a live version skip the delivery with their template rule, and otherwise the template, layout and partial versions and the locale are pinned with the delivery (TP-50, TP-11, TP-26, WF-16). In `dry_run` the template step and the lattice run and the answer carries each channel's decision; nothing is opened, pinned or counted (PC-58 (8)). A durable write failure is `503` (INV-2).
  """

  alias Relay.Api.Schema
  alias Relay.Api.Views
  alias Relay.Api.WorkflowRuns
  alias Relay.Policy.Live
  alias Relay.Scope
  alias Relay.Templates.Live, as: Templates
  alias Relay.Tenancy.KillSwitch

  @channels Map.new(
              ~w(push web_push email sms voice whatsapp slack teams telegram discord in_app
                 webhook)a,
              &{Atom.to_string(&1), &1}
            )
  @classes Map.new(
             ~w(security transactional operational social marketing system action_required)a,
             &{Atom.to_string(&1), &1}
           )
  @priorities %{"low" => :low, "normal" => :normal, "high" => :high}
  @no_readings %{global: nil, policy: nil}
  @domestic "channels.domestic_only"
  @shards 16
  @test_per_day Relay.Limits.fetch!(["test_send", "max_notifications_per_day"])

  @type context :: %{
          required(:scope) => Scope.t(),
          required(:actor) => Relay.Actor.t(),
          optional(:api_client_id) => String.t() | nil,
          optional(:subtenant_id) => Relay.Id.t() | nil,
          optional(:traceparent) => String.t() | nil,
          optional(:agent) => boolean()
        }

  @type prepared :: map()
  @type row :: {non_neg_integer(), String.t() | nil, {:ok, prepared()} | {:error, error()}}
  @type error :: Relay.Error.t()

  # API-19
  # API-20
  # API-21
  # API-27
  # WF-7
  # API-81
  # WF-52
  @doc "Prepares a native event request outside any transaction. `opts`: `:source` (`:api` or `:cloudevents`), `:cloudevent` (its attributes) and `:dedup_key`."
  @spec prepare(context(), map(), keyword()) :: {:ok, prepared()} | {:error, Relay.Error.t()}
  def prepare(%{scope: scope} = ctx, body, opts \\ []) do
    cloudevent = Keyword.get(opts, :cloudevent)

    with {:ok, workflow} <- workflow(scope, body["workflow"]),
         {:ok, routes} <- routes(scope, workflow),
         steps = Relay.Workflow.route_steps(workflow["definition"], routes),
         {:ok, tenant} <- tenant_settings(scope, workflow, steps),
         {:ok, category} <- category(scope, workflow, nil),
         class = Atom.to_string(category.message_class),
         {:ok, request} <-
           Relay.Ingest.check_request(body, %{
             message_class: class,
             steps: steps,
             environment: scope.environment,
             now: Relay.Clock.utc_now(),
             agent: Map.get(ctx, :agent, false)
           }),
         {:ok, request} <- Relay.Topics.expand(scope, request),
         :ok <- event_data(workflow, request.data),
         :ok <- simulated(scope, request.targets),
         {:ok, providers} <- overrides(scope, workflow, request, tenant.settings),
         :ok <- platform(class),
         {:ok, recipients} <- recipients(scope, request.targets),
         {:ok, recipients} <- WorkflowRuns.attributes(scope, workflow["definition"], recipients),
         {:ok, payload} <- payload(scope, request, cloudevent),
         {:ok, subtenant} <- subtenant(scope, request.tenant, Map.get(ctx, :subtenant_id)),
         {:ok, category} <- subtenant_category(scope, workflow, category, subtenant) do
      request = clamp(request, body, category.message_class)
      now = Relay.Clock.business_now(scope)

      {:ok,
       %{
         scope: scope,
         event_id: Relay.Id.generate(),
         workflow: workflow,
         routes: routes,
         category: workflow["definition"]["category"],
         policy: category,
         message_class: class,
         now: now,
         expires_at: expires_at(request, category, now),
         frequency: frequency(scope, category, recipients, request.steps),
         request: request,
         providers: providers,
         recipients: recipients,
         payload: payload,
         settings: tenant.settings,
         installation_mode: tenant.installation_mode,
         subtenant: subtenant,
         source: Keyword.get(opts, :source, :api),
         ce_key_digest: ce_digest(cloudevent),
         dedup_key: request.dedup_key || Keyword.get(opts, :dedup_key),
         traceparent: (cloudevent && cloudevent["traceparent"]) || Map.get(ctx, :traceparent),
         api_client_id: api_client(Map.get(ctx, :api_client_id))
       }}
    end
  end

  # WF-14
  # WF-7
  defp routes(scope, workflow) do
    case Relay.Workflow.prepare_routes(scope, workflow["definition"]) do
      {:ok, routes} -> {:ok, routes}
      {:error, _reason} -> {:error, unavailable("the routes could not be read")}
    end
  end

  defp ce_digest(nil), do: nil
  defp ce_digest(event), do: Relay.Ingest.ce_key_digest(event["source"], event["id"])

  # PC-57 (3)
  defp category(scope, workflow, subtenant_id) do
    key = workflow["definition"]["category"] || workflow["message_class"]
    class = Map.fetch!(@classes, workflow["message_class"])

    case Live.category(scope, key, class, subtenant_id) do
      {:ok, category} -> {:ok, category}
      {:error, _reason} -> {:error, unavailable("the category could not be read")}
    end
  end

  # PC-57 (2)
  defp subtenant_category(scope, workflow, _category, {:ok, id}),
    do: category(scope, workflow, id)

  defp subtenant_category(_scope, _workflow, category, _subtenant), do: {:ok, category}

  # API-22
  # PC-58 (7)
  defp clamp(request, body, class) do
    {priority, clamped?} = Live.clamp_priority(class, Map.get(@priorities, body["priority"]))
    kept = Enum.reject(request.warnings, &(&1["code"] == "priority_clamped"))
    warnings = if clamped?, do: kept ++ [clamped(priority)], else: kept
    %{request | priority: Atom.to_string(priority), warnings: warnings}
  end

  defp clamped(priority) do
    detail = "the class allows at most #{priority}"
    %{"code" => "priority_clamped", "pointer" => "/priority", "detail" => detail}
  end

  # PC-49
  # PC-57 (4)
  defp expires_at(%{expires_at: %DateTime{} = at}, _category, _now), do: at

  defp expires_at(request, category, now),
    do: Live.default_expires_at(category, category.message_class, request.send_at || now)

  # PC-58 (6)
  defp frequency(scope, category, recipients, steps) do
    for %{plan: %{id: recipient_id}} <- recipients,
        recipient_id != nil,
        %{channel: name} <- steps,
        channel = Map.fetch!(@channels, name),
        into: %{} do
      readings = Live.frequency(scope, category, category.message_class, recipient_id, channel)
      {{recipient_id, channel}, readings}
    end
  end

  @doc "The lane class and channels of a prepared event, for admission control."
  @spec admission(prepared()) :: {atom(), [atom()]}
  def admission(prepared) do
    {Map.fetch!(@classes, prepared.message_class),
     Enum.map(prepared.request.steps, &Map.fetch!(@channels, &1.channel))}
  end

  defp workflow(scope, key) do
    case Relay.Workflow.resolve_published(scope, key) do
      {:ok, {:ok, workflow}} ->
        {:ok, workflow}

      {:ok, :not_found} ->
        {:error, Relay.Error.new(:workflow_not_found, "no workflow has this key")}

      {:ok, :not_published} ->
        {:error, not_published()}

      {:error, _reason} ->
        {:error, Relay.Error.new(:service_unavailable, "the workflow could not be read")}
    end
  end

  # API-27
  defp event_data(workflow, data) do
    with {:ok, root} <- schema(workflow["event_schema"]),
         {:error, error} <- Schema.validate(root, data) do
      errors = Enum.map(error.details.errors, &%{&1 | pointer: "/data" <> &1.pointer})

      {:error,
       Relay.Error.new(:validation_failed, "data does not match the event schema", %{
         errors: errors
       })}
    end
  end

  defp schema(event_schema) do
    case Relay.Workflow.event_schema(event_schema) do
      {:ok, root} -> {:ok, root}
      {:error, _detail} -> :ok
    end
  end

  # TN-40 (1)
  defp platform(class) do
    if KillSwitch.platform_stopped?(class) do
      message = "sending is stopped platform wide"
      {:error, Relay.Error.new(:service_unavailable, message, %{retry_after: 30})}
    else
      :ok
    end
  end

  # API-21
  defp recipients(scope, targets) do
    targets
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {target, index}, {:ok, acc} ->
      {external_id, input, mode} =
        case target do
          {:require, id} -> {id, %{external_id: id, fields: %{}}, :require}
          {:inbox_only, id} -> {id, %{external_id: id, fields: %{}}, :inbox_only}
          {:implicit, id, fields} -> {id, %{external_id: id, fields: fields}, :implicit}
        end

      case Relay.Subscribers.prepare(scope, input, mode) do
        {:ok, plan} -> {:cont, {:ok, [recipient(plan, index, external_id, input) | acc]}}
        {:error, %Relay.Error{} = error} -> {:halt, {:error, error}}
        {:error, _reason} -> {:halt, {:error, unavailable("the recipient could not be prepared")}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp recipient(plan, index, external_id, input),
    do: %{plan: plan, index: index, external_id: external_id, fields: input.fields}

  defp payload(scope, request, cloudevent) do
    with {:ok, key_id} <- Relay.Tenancy.active_tenant_key(scope, :data),
         {:ok, key} <- Relay.Tenancy.data_key(field(scope, key_id, "data_ct")),
         {:ok, data_ct} <- seal(scope, key_id, "data_ct", request.data, key),
         {:ok, metadata_ct} <- seal(scope, key_id, "metadata_ct", request.metadata, key),
         {:ok, actor_ct} <- seal(scope, key_id, "actor_ct", request.actor, key),
         {:ok, links_ct} <- seal(scope, key_id, "links_ct", request.links, key),
         ce = ce_attributes(cloudevent),
         {:ok, ce_ct} <- seal(scope, key_id, "ce_attributes_ct", ce, key),
         overrides = if(request.overrides in [nil, %{}], do: nil, else: request.overrides),
         {:ok, overrides_ct} <- seal(scope, key_id, "overrides_ct", overrides, key) do
      {:ok,
       %{
         key_id: key_id,
         data_ct: data_ct,
         metadata_ct: metadata_ct,
         actor_ct: actor_ct,
         links_ct: links_ct,
         ce_attributes_ct: ce_ct,
         overrides_ct: overrides_ct,
         plain_size: byte_size(Jason.encode!(request.data))
       }}
    end
  end

  defp ce_attributes(nil), do: nil
  defp ce_attributes(event), do: Map.take(event, ~w(id source type subject time))

  defp seal(_scope, _key_id, _column, nil, _key), do: {:ok, nil}

  defp seal(scope, key_id, column, value, key) do
    Relay.Tenancy.encrypt_field(field(scope, key_id, column), Jason.encode!(value), data_key: key)
  end

  defp field(scope, key_id, column) do
    %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: nil,
      retention_class: :notification_content,
      table: "event_payloads",
      column: column,
      key_id: key_id
    }
  end

  # OP-51
  defp tenant_settings(scope, workflow, steps) do
    category = workflow["definition"]["category"]
    key = workflow["key"]
    modes = Enum.flat_map(steps, &Relay.Ingest.send_mode_keys(key, category, &1.channel))
    providers = Enum.map(steps, &"overrides.#{&1.channel}.provider")
    keys = Enum.uniq([@domestic | modes ++ providers])

    read = fn _status -> %{settings: Relay.Ingest.settings(keys)} end

    with {:ok, tenant} <- Relay.Ingest.in_event_scope(scope, read),
         {:ok, mode} <- Relay.Ingest.installation_send_mode() do
      {:ok, Map.put(tenant, :installation_mode, mode)}
    else
      {:error, _reason} -> {:error, unavailable("the send mode could not be read")}
    end
  end

  # CH-72
  # X-25
  defp simulated(%Scope{environment: :live}, targets) do
    found =
      for {{:implicit, _id, details}, index} <- Enum.with_index(targets),
          {field, channel} <- [{"email", "email"}, {"phone", "sms"}],
          value = details[field],
          is_binary(value),
          Relay.Channels.simulated_address?(channel, value),
          do: "/to/#{index}/#{field}"

    case found do
      [] ->
        :ok

      [pointer | _] ->
        message = "a simulated address is accepted only in test (#{pointer})"
        {:error, Relay.Error.new(:recipient_invalid, message)}
    end
  end

  defp simulated(_scope, _targets), do: :ok

  # API-23
  # CH-6
  # TN-58
  defp overrides(scope, workflow, request, settings) do
    definition = workflow["definition"]
    tenant = tenant_overrides(settings)

    providers =
      for step <- request.steps,
          provider = provider(request.overrides, definition, step, tenant),
          into: %{},
          do: {provider_key(step), {step.channel, provider}}

    pairs = providers |> Map.values() |> Enum.uniq()
    policy = %{domestic_country: settings[@domestic]}

    froms =
      for %{channel: "email"} = step <- request.steps,
          from = effective(request.overrides, definition, step)["from"],
          is_binary(from),
          uniq: true,
          do: from

    case check_overrides(scope, pairs, froms, policy) do
      {:ok, :ok} ->
        {:ok, Map.new(providers, fn {key, {_channel, provider}} -> {key, provider} end)}

      {:ok, {:not_configured, channel, :provider}} ->
        message = "no verified provider account of the requested provider on #{channel}"
        {:error, Relay.Error.new(:channel_not_configured, message)}

      {:ok, {:not_configured, _channel, :from}} ->
        message = "the sender address is not on a verified domain"
        {:error, Relay.Error.new(:channel_not_configured, message)}

      {:error, %Relay.Error{} = error} ->
        {:error, error}

      {:error, _reason} ->
        {:error, unavailable("the provider routes could not be read")}
    end
  end

  defp check_overrides(_scope, [], [], _policy), do: {:ok, :ok}

  defp check_overrides(scope, pairs, froms, policy) do
    case Relay.Datasets.channel_declarations() do
      {:ok, declarations} ->
        Relay.Channels.check_overrides(scope, pairs, froms, declarations, policy)

      {:error, _error} ->
        {:error, unavailable("the channel declarations could not be read")}
    end
  end

  @doc "The key of a prepared step's provider: its step key and channel, since a route step sends on every channel of its tree."
  @spec provider_key(map()) :: String.t()
  def provider_key(step), do: "#{step.key}:#{step.channel}"

  defp provider(requested, definition, step, tenant) do
    levels = [requested, own_overrides(definition, step), definition["overrides"], tenant]
    Relay.Channels.requested_provider(levels, step.channel)
  end

  defp effective(requested, definition, step) do
    levels = [requested, own_overrides(definition, step), definition["overrides"]]
    Relay.Channels.effective_override(levels, step.channel)
  end

  defp own_overrides(definition, step) do
    steps = Map.get(definition, "steps", [])
    Enum.find_value(steps, &(is_map(&1) and &1["key"] == step.key and &1["overrides"]))
  end

  defp tenant_overrides(settings) do
    for {"overrides." <> rest, provider} <- settings,
        is_binary(provider),
        [channel, "provider"] <- [String.split(rest, ".")],
        into: %{},
        do: {channel, %{"provider" => provider}}
  end

  # API-25
  defp subtenant(scope, requested, bound) do
    case Relay.Access.select_subtenant(scope, bound, requested) do
      {:ok, nil} -> {:ok, nil}
      {:ok, id} -> {:ok, {:ok, id}}
      {:skipped, :scope_mismatch} -> {:ok, :mismatch}
      {:error, _reason} -> {:error, unavailable("the sub-tenant could not be read")}
    end
  end

  defp api_client(nil), do: nil

  defp api_client(text) do
    case Relay.ExternalId.decode(text, ["cli"]) do
      {:ok, id} -> id
      {:error, _error} -> nil
    end
  end

  # OP-7
  # DS-36
  # INV-2
  # API-16
  # API-51
  # TN-40
  @doc "Accepts a prepared event inside the caller's idempotency transaction and returns the accept answer, or an error that rolls everything back."
  @spec accept(prepared(), context()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def accept(prepared, ctx) do
    with :ok <- lock(prepared),
         :ok <- quota(prepared),
         {:ok, event} <- event(prepared),
         :ok <- Relay.Topics.record(prepared.request, event.id),
         prepared = templates(prepared),
         {:ok, notifications} <- notifications(prepared, event, ctx) do
      {:ok,
       Views.event_accepted(%{
         id: prepared.event_id,
         workflow_key: prepared.workflow["key"],
         workflow_version: prepared.workflow["version_no"],
         recipient_count: length(prepared.recipients),
         notifications: notifications,
         warnings: prepared.request.warnings,
         created_at: event.created_at
       })}
    end
  end

  # API-58
  # INV-60
  defp lock(%{request: %{cancellation_key: nil}}), do: :ok

  defp lock(%{scope: scope, request: %{cancellation_key: key}}) do
    Relay.Ingest.cancellation_lock(
      "cancel:" <> Scope.tenant_text(scope) <> Atom.to_string(scope.environment) <> key
    )
  end

  # API-61
  defp quota(%{is_test: true} = prepared) do
    count = max(length(prepared.recipients), 1)

    case Relay.Ingest.test_send_consume(count, @test_per_day) do
      {:consumed, _used} ->
        :ok

      {:exhausted, used} ->
        message = "the day's test send quota is exhausted"

        {:error,
         Relay.Error.new(:quota_exhausted, message, %{
           limit: @test_per_day,
           actual: used,
           limit_name: "test_send.max_notifications_per_day"
         })}
    end
  end

  # API-51
  # API-79 (1)
  # TN-52
  defp quota(prepared) do
    shard = :erlang.phash2(prepared.event_id, @shards)
    count = max(length(prepared.recipients), 1)

    case Enum.find(
           Relay.Ingest.quota_consume(prepared.message_class, count, shard),
           &(&1["result"] in [:exhausted, :class_cap])
         ) do
      nil -> :ok
      row -> {:error, quota_error(row, prepared.message_class)}
    end
  end

  defp quota_error(row, class) do
    quota =
      %{
        "bucket" => if(class == "security", do: "security", else: "general"),
        "period" => row["period"]
      }
      |> then(&if(row["result"] == :class_cap, do: Map.put(&1, "message_class", class), else: &1))
      |> then(&if(class == "security", do: Map.put(&1, "reserve", true), else: &1))

    Relay.Error.new(:quota_exhausted, "the #{row["period"]} quota is exhausted", %{
      quota: quota,
      limit: row["limit_total"],
      actual: row["used"]
    })
  end

  defp event(p) do
    r = p.request

    attrs = %{
      id: p.event_id,
      workflow_id: p.workflow["workflow_id"],
      workflow_version_id: p.workflow["version_id"],
      api_client_id: p.api_client_id,
      subtenant_id: subtenant_id(p.subtenant),
      source: Atom.to_string(p.source),
      ce_key_digest: p.ce_key_digest,
      dedup_key: p.dedup_key,
      cancellation_key: r.cancellation_key,
      sender_type: r.sender_type,
      priority: r.priority,
      security_subtype: r.security_subtype,
      on_expire: r.on_expire,
      send_at: r.send_at,
      expires_at: r.expires_at,
      retention_none: r.retention_none,
      send_mode: r.send_mode,
      interruption: r.interruption,
      correlation_id: r.correlation_id,
      item: r.item,
      is_test: Map.get(p, :is_test, false),
      recipient_count: length(p.recipients),
      traceparent: p.traceparent
    }

    case Relay.Ingest.event_accept(Map.merge(attrs, p.payload)) do
      {:accepted, id, created_at} ->
        {:ok, %{id: id, created_at: created_at}}

      {:workflow_not_published, _id, _at} ->
        {:error, not_published()}

      {:version_not_current, _id, _at} ->
        {:error, unavailable("the workflow version changed; retry")}

      {:send_mode_not_allowed, _id, _at} ->
        {:error, Relay.Error.new(:auth_environment_mismatch, "a send mode is test only")}

      {:send_at_invalid, _id, _at} ->
        error = %{pointer: "/send_at", code: "invalid_format", detail: "at most 90 days ahead"}
        message = "send_at is out of range"
        {:error, Relay.Error.new(:validation_failed, message, %{errors: [error]})}

      {suspended, _id, _at} when suspended in [:subtenant_suspended, :tenant_inactive] ->
        {:error, Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")}
    end
  end

  defp subtenant_id({:ok, id}), do: id
  defp subtenant_id(_other), do: nil

  # TP-50
  # TP-36
  defp templates(p) do
    keys =
      p.request.steps
      |> Enum.flat_map(&[&1.template, Map.get(&1, :digest_template)])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Map.put(p, :templates, Templates.templates(keys, subtenant_id(p.subtenant)))
  end

  defp notifications(p, event, ctx) do
    Enum.reduce_while(p.recipients, {:ok, []}, fn recipient, {:ok, acc} ->
      case notification(p, event, recipient, ctx) do
        {:ok, accepted} -> {:cont, {:ok, [accepted | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  # API-21
  # API-16
  # API-25
  defp notification(p, event, %{plan: plan, index: index, external_id: external_id} = r, ctx) do
    ctx = Map.put(ctx, :attributes, Map.get(r, :attributes, %{}))

    with {:ok, recipient_id} <- upsert(plan, index),
         {:ok, result, id, original, mismatch?} <- open_notification(p, event, recipient_id),
         {:ok, decisions} <- created(result, p, id, recipient_id, mismatch?, ctx) do
      duplicate_of = if result == :duplicate, do: original
      {:ok, entry(recipient_id, external_id, id, duplicate_of, decisions)}
    end
  end

  defp created(:created, p, id, recipient_id, mismatch?, ctx) do
    row = device_locale(Relay.Subscribers.row(recipient_id), recipient_id)
    start_run(p, id, row, mismatch?, ctx)
  end

  defp created(:duplicate, _p, _id, _recipient_id, _mismatch?, _ctx), do: {:ok, []}

  # WF-59 (5)
  # WF-41
  # WF-6
  defp start_run(p, notification_id, row, mismatch?, ctx) do
    definition = p.workflow["definition"]

    run = %{
      notification_id: notification_id,
      recipient_id: row["id"],
      workflow_key: p.workflow["key"],
      message_class: p.message_class,
      definition: definition,
      plan: WorkflowRuns.plan(p, row, mismatch?),
      context: WorkflowRuns.context(p, row, Map.get(ctx, :attributes, %{})),
      now: p.request.send_at || p.now,
      opener: fn step, channel, pointer ->
        open_step(p, notification_id, row, mismatch?, step, {channel, pointer})
      end
    }

    case Relay.Workflow.start_run(p.scope, run) do
      {:ok, decisions} -> {:ok, decisions}
      {:error, %Relay.Error{} = error} -> {:error, error}
      {:error, _reason} -> {:error, unavailable("the workflow run could not be started")}
    end
  end

  # WF-59 (5)
  # WF-8
  # WF-63
  # WF-27
  @doc "Opens the delivery of a route leaf of a run's channel step inside the accepting or the waking transaction: the prepared step of the same key and channel, keyed in the ledger by the step key and the leaf pointer (WF-63), with the step's digest template when the run carries a fired digest; nothing when the request's `channels` narrowed the channel away. Returns the opened delivery's identifier and the step's dry-run decisions."
  @spec open_step(prepared(), Relay.Id.t(), map(), boolean(), map(), {String.t(), String.t()}) ::
          {:ok, [String.t()], [map()]} | {:error, error()}
  def open_step(p, notification_id, row, mismatch?, %{"key" => key} = leaf, {channel, pointer}) do
    case Enum.find(p.request.steps, &(&1.key == key and &1.channel == channel)) do
      nil ->
        {:ok, [], []}

      step ->
        step = %{
          key: step.key,
          channel: step.channel,
          template: leaf["template"] || step.template,
          skip: step.skip,
          step_ref: key <> pointer
        }

        case open_delivery(p, notification_id, row, mismatch?, step) do
          {:ok, decisions, nil} -> {:ok, [], decisions}
          {:ok, decisions, id} -> {:ok, [Relay.Id.to_string(id)], decisions}
          {:error, error} -> {:error, error}
        end
    end
  end

  # TP-25
  @doc "The subscriber row with the locale of its most recently seen device that carries one (TP-25), inside the caller's scoped transaction."
  @spec device_locale(map() | nil, Relay.Id.t()) :: map() | nil
  def device_locale(%{} = row, recipient_id) do
    locale = Enum.find_value(Relay.Devices.current(recipient_id), & &1["locale"])
    Map.put(row, "device_locale", locale)
  end

  def device_locale(row, _recipient_id), do: row

  defp entry(recipient_id, external_id, notification_id, duplicate_of, decisions) do
    Views.accepted_notification(%{
      recipient_kind: "subscriber",
      recipient_id: recipient_id,
      external_id: external_id,
      notification_id: notification_id,
      duplicate_of: duplicate_of,
      decisions: decisions
    })
  end

  defp upsert(plan, index) do
    case Relay.Subscribers.upsert(plan, nil) do
      {result, id, _version} when result in [:created, :updated, :unchanged] ->
        {:ok, id}

      {:recipient_not_found, _id, _version} ->
        {:error,
         Relay.Error.new(:recipient_not_found, "no subscriber has this id", %{
           errors: [%{pointer: "/to/#{index}", code: "not_found", detail: "unknown subscriber"}]
         })}

      {result, _id, _version} when result in [:is_agent, :deletion_pending] ->
        error = %{pointer: "/to/#{index}", code: "not_allowed", detail: Atom.to_string(result)}

        {:error,
         Relay.Error.new(:recipient_invalid, "the recipient cannot receive this event", %{
           errors: [error]
         })}

      {:tenant_inactive, _id, _version} ->
        {:error, Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")}

      {_exists_or_conflict, _id, _version} ->
        {:error, unavailable("the recipient changed concurrently; retry")}
    end
  end

  defp open_notification(p, event, recipient_id) do
    attrs = %{
      id: Relay.Id.generate(),
      recipient_id: recipient_id,
      subtenant_id: subtenant_id(p.subtenant),
      dedup_key: p.dedup_key || "evt:" <> Relay.Id.to_string(event.id),
      message_class: p.message_class,
      security_subtype: p.request.security_subtype,
      sender_type: p.request.sender_type,
      expires_at: p.expires_at,
      is_test: Map.get(p, :is_test, false),
      traceparent: p.traceparent,
      event_id: event.id,
      workflow_id: p.workflow["workflow_id"],
      workflow_version_id: p.workflow["version_id"]
    }

    case Relay.Ingest.event_notification_accept(attrs) do
      {:subtenant_not_found, _id, _original} ->
        open_mismatch(%{attrs | id: Relay.Id.generate(), subtenant_id: nil})

      result ->
        notification_result(result, p.subtenant == :mismatch)
    end
  end

  defp open_mismatch(attrs),
    do: notification_result(Relay.Ingest.event_notification_accept(attrs), true)

  defp notification_result({result, id, original}, mismatch?)
       when result in [:created, :duplicate],
       do: {:ok, result, id, original, mismatch?}

  defp notification_result({:recipient_not_found, _id, _original}, _mismatch?),
    do: {:error, Relay.Error.new(:recipient_invalid, "the recipient is not active")}

  defp notification_result({_inactive, _id, _original}, _mismatch?),
    do: {:error, Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")}

  # OP-51
  # TN-40
  # API-25
  # API-24
  # PC-58 (2)
  # PC-58 (8)
  # INV-15
  # C-89
  defp open_delivery(p, notification_id, row, mismatch?, step) do
    mode =
      Relay.Ingest.send_mode(
        p.request.send_mode,
        p.settings,
        p.workflow["key"],
        p.category,
        step.channel,
        p.installation_mode
      )

    delivery_id = Relay.Id.generate()

    case {gate(p, step, row, mismatch?, mode), mode} do
      {{:skip, reason, rule, _detail}, :dry_run} ->
        {:ok, [Live.dry_run_skip(step.channel, reason, rule)], nil}

      {{:skip, reason, rule, detail}, _mode} ->
        skip(p, notification_id, row, step, delivery_id, {reason, rule, detail})

      {{:ok, _plan}, :dry_run} ->
        dry_run(step.channel, Live.decide(lattice_input(p, row, step, delivery_id)))

      {{:ok, plan}, _mode} ->
        result = Live.decide(lattice_input(p, row, step, delivery_id))
        opened(p, notification_id, row, step, {delivery_id, plan}, result)
    end
  end

  # WF-16
  # TP-11
  # TP-26
  # TP-51
  defp gate(p, step, row, mismatch?, mode) do
    case decision(step, row, mismatch?, mode) do
      {:skip, reason, rule} -> {:skip, reason, rule, %{}}
      :lattice -> Templates.choose(p.templates, step, row)
    end
  end

  # DS-24
  defp skip(p, notification_id, row, step, delivery_id, {reason, rule, detail}) do
    case open(p, notification_id, row, step, delivery_id) do
      {:ok, nil} ->
        {:ok, [], nil}

      {:ok, id} ->
        _ = Live.record_skip(id, reason, rule, detail)
        {:ok, [], id}

      {:error, error} ->
        {:error, error}
    end
  end

  # TN-73
  # MD-12
  defp decision(_step, %{"suspended_at" => %DateTime{}}, _mismatch?, _mode),
    do: {:skip, "subscriber_suspended", "subscriber.suspended"}

  defp decision(%{skip: {reason, rule}}, _row, _mismatch?, _mode), do: {:skip, reason, rule}
  defp decision(_step, _row, true, _mode), do: {:skip, "scope_mismatch", "scope.mismatch"}
  defp decision(_step, _row, _mismatch?, :off), do: {:skip, "send_mode_off", "send_mode.off"}
  defp decision(_step, _row, _mismatch?, _mode), do: :lattice

  # PC-58 (8)
  defp dry_run(channel, result) do
    case Live.dry_run(channel, result) do
      {:ok, decision} -> {:ok, [decision], nil}
      :error -> {:error, unavailable("a policy input could not be read")}
    end
  end

  # PC-58 (1)
  defp lattice_input(p, row, step, delivery_id) do
    channel = Map.fetch!(@channels, step.channel)

    %{
      scope: p.scope,
      now: p.request.send_at || p.now,
      delivery_id: delivery_id,
      recipient_id: row["id"],
      subtenant_id: subtenant_id(p.subtenant),
      channel: channel,
      category: p.policy,
      workflow_key: p.workflow["key"],
      notification:
        Live.notification(%{
          message_class: p.message_class,
          security_subtype: p.request.security_subtype,
          priority: p.request.priority,
          expires_at: p.expires_at,
          sender_type: p.request.sender_type
        }),
      frequency: Map.get(p.frequency, {row["id"], channel}, @no_readings)
    }
  end

  # DS-24
  # DS-27
  # INV-43
  # TP-50
  # INV-48
  defp opened(p, notification_id, row, step, {delivery_id, plan}, result) do
    case open(p, notification_id, row, step, delivery_id) do
      {:ok, nil} ->
        {:ok, [], nil}

      {:ok, id} ->
        with {:ok, decisions} <- pinned(Templates.pin(id, plan), p, notification_id, id, result),
             do: {:ok, decisions, id}

      {:error, error} ->
        {:error, error}
    end
  end

  defp pinned(:pinned, p, notification_id, id, result),
    do: after_open(p, notification_id, id, result)

  defp pinned(_not_pinned, _p, _notification_id, _id, _result),
    do: {:error, unavailable("the render plan could not be pinned")}

  defp after_open(p, notification_id, id, {:send, _info} = result) do
    _ = Live.record(id, result)
    enqueue(p, notification_id, id, p.request.send_at)
  end

  defp after_open(p, notification_id, id, {:defer, _reason, _rule, until, _detail} = result) do
    _ = Live.record(id, result)
    enqueue(p, notification_id, id, Relay.Clock.wall_time(p.scope, until))
  end

  defp after_open(p, notification_id, id, {:error, _input_unavailable}),
    do: enqueue(p, notification_id, id, p.request.send_at)

  defp after_open(_p, _notification_id, id, skip_or_expire) do
    _ = Live.record(id, skip_or_expire)
    {:ok, []}
  end

  defp open(p, notification_id, row, step, delivery_id) do
    delivery = %{
      id: delivery_id,
      channel: Map.fetch!(@channels, step.channel),
      target_kind: target_kind(step.channel),
      target_id: test_device(p, step.channel, row["id"]),
      target_key: target_key(step.channel, row["id"]),
      decision: :send,
      decision_reason: nil,
      decision_rule_id: nil,
      deferred_until: nil,
      provider: Map.get(p.providers, provider_key(step)),
      step_ref: Map.get(step, :step_ref, ""),
      traceparent: p.traceparent
    }

    case Relay.Ingest.delivery_open(notification_id, delivery) do
      {:opened, id} -> {:ok, id}
      {:exists, _id} -> {:ok, nil}
      {_other, _id} -> {:error, unavailable("the delivery could not be opened")}
    end
  end

  # API-61
  defp test_device(%{test_devices: devices}, channel, recipient_id)
       when channel in ["push", "web_push"],
       do: Map.get(devices, recipient_id)

  defp test_device(_p, _channel, _recipient_id), do: nil

  defp target_kind(channel) when channel in ~w(email sms voice whatsapp), do: :address
  defp target_kind("in_app"), do: :inbox
  defp target_kind(channel) when channel in ~w(push web_push), do: :device
  defp target_kind(_channel), do: :endpoint

  defp target_key(channel, recipient_id) do
    :crypto.hash(:sha256, Relay.Canonical.encode!(["target", channel, {:bytes, recipient_id}]))
  end

  # T-15
  # TN-40 (1)
  defp enqueue(p, notification_id, delivery_id, at) do
    case KillSwitch.at_acceptance(delivery_id) do
      {:paused, _rule_id} ->
        {:ok, []}

      _allow_or_hold ->
        class = Map.fetch!(@classes, p.message_class)

        job = %{
          id: Relay.Id.generate(),
          lane: Relay.Platform.lane(class),
          worker: Relay.Delivery.send_worker(),
          args:
            p.scope
            |> Scope.to_job_args()
            |> Map.merge(%{
              "notification_id" => Relay.Id.to_string(notification_id),
              "delivery_id" => Relay.Id.to_string(delivery_id)
            }),
          ref_kind: "delivery",
          ref_id: delivery_id,
          priority: Relay.Platform.job_priority(:delivery, 1, @priorities[p.request.priority]),
          scheduled_at: at
        }

        case Relay.Platform.enqueue_job(job) do
          {:ok, _queued} -> {:ok, []}
          {:error, _error} -> {:error, unavailable("the delivery job could not be queued")}
        end
    end
  end

  @whole_request [:quota_exhausted, :auth_tenant_suspended, :auth_environment_mismatch]
  @limits Relay.Api.Contract.limits()["batch"]

  # API-32
  # API-33
  # API-34
  @doc "Accepts the prepared rows of a batch inside the request's transaction, each in its own savepoint: `202` when every row is accepted, `207` when some are, `422` when none are. A quota, suspension or environment error answers the whole request (API-32); `problem` renders a rejected row's problem."
  @spec batch([row()], context(), (Relay.Error.t() -> map())) ::
          {:ok, {100..599, list(), map()}} | {:error, Relay.Error.t()}
  def batch(rows, ctx, problem) do
    outcomes = for {index, ref, prepared} <- rows, do: {index, ref, row(prepared, ctx)}

    case Enum.find_value(outcomes, &whole_request/1) do
      nil -> {:ok, batch_answer(outcomes, problem)}
      error -> {:error, error}
    end
  end

  defp row({:ok, prepared}, ctx), do: Relay.Ingest.savepoint(fn -> accept(prepared, ctx) end)
  defp row({:error, error}, _ctx), do: {:error, error}

  defp whole_request({_index, _ref, {:error, %Relay.Error{code: code} = error}})
       when code in @whole_request,
       do: error

  defp whole_request(_outcome), do: nil

  defp batch_answer(outcomes, problem) do
    results =
      for {index, ref, outcome} <- outcomes do
        base = Views.put_unless_nil(%{"index" => index}, "ref", ref)

        case outcome do
          {:ok, event} -> Map.merge(base, %{"status" => "accepted", "event" => event})
          {:error, e} -> Map.merge(base, %{"status" => "rejected", "error" => problem.(e)})
        end
      end

    total = length(results)
    accepted = Enum.count(results, &(&1["status"] == "accepted"))

    status =
      cond do
        accepted == total -> 202
        accepted == 0 -> 422
        true -> 207
      end

    {status, batch_headers(),
     %{
       "object" => "batch_result",
       "summary" => %{"total" => total, "accepted" => accepted, "rejected" => total - accepted},
       "results" => results
     }}
  end

  # API-33
  @doc "The batch limit headers of every batch answer."
  @spec batch_headers() :: [{String.t(), String.t()}]
  def batch_headers do
    [
      {"relay-batch-max-events", Integer.to_string(@limits["max_events"])},
      {"relay-batch-max-recipients-per-event",
       Integer.to_string(@limits["max_recipients_per_event"])}
    ]
  end

  defp not_published,
    do: Relay.Error.new(:workflow_not_published, "the workflow has no published version")

  defp unavailable(message),
    do: Relay.Error.new(:service_unavailable, message, %{retry_after: 1})
end
