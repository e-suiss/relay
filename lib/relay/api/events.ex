defmodule Relay.Api.Events do
  @moduledoc """
  The send operations (API-19 … API-34, OP-7, DS-36). An event is prepared outside any transaction (`prepare/3`): its workflow version is resolved and frozen (WF-7), the request's field rules and the event schema are checked (API-20, API-27), the recipients' writes are prepared with their keys (API-21) and the payload is sealed under the tenant data key. It is then accepted inside the request's idempotency transaction (`accept/2`), so the idempotency claim, the event, its notifications and deliveries with their opening ledger events, the queue jobs, the quota counters and the outbox events commit together or not at all.

  Policy outcomes are decisions, not errors (C-4, MD-12): a matching kill switch pauses the delivery at acceptance and queues no job (TN-40), the send mode `off` and an unknown sub-tenant skip it with a rule (OP-51, API-25), and a recipient without an address for a step's channel is skipped as well. A durable write failure is `503` (INV-2).
  """

  alias Relay.Api.Schema
  alias Relay.Api.Views
  alias Relay.Scope
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
  @address_channels %{
    "email" => "email_state",
    "sms" => "phone_state",
    "voice" => "phone_state",
    "whatsapp" => "phone_state"
  }
  @shards 16

  @type context :: %{
          required(:scope) => Scope.t(),
          required(:actor) => Relay.Actor.t(),
          optional(:api_client_id) => String.t() | nil,
          optional(:subtenant_id) => Relay.Id.t() | nil,
          optional(:traceparent) => String.t() | nil
        }

  @type prepared :: map()
  @type row :: {non_neg_integer(), String.t() | nil, {:ok, prepared()} | {:error, error()}}
  @type error :: Relay.Error.t()

  # API-19
  # API-20
  # API-21
  # API-27
  # WF-7
  @doc "Prepares a native event request outside any transaction. `opts`: `:source` (`:api` or `:cloudevents`), `:cloudevent` (its attributes) and `:dedup_key`."
  @spec prepare(context(), map(), keyword()) :: {:ok, prepared()} | {:error, Relay.Error.t()}
  def prepare(%{scope: scope} = ctx, body, opts \\ []) do
    cloudevent = Keyword.get(opts, :cloudevent)

    with {:ok, workflow} <- workflow(scope, body["workflow"]),
         steps = Relay.Workflow.steps(workflow["definition"]),
         {:ok, tenant} <- tenant_settings(scope, workflow, steps),
         class = message_class(tenant.platform_product, workflow["message_class"]),
         {:ok, request} <-
           Relay.Ingest.check_request(body, %{
             message_class: class,
             steps: steps,
             environment: scope.environment,
             now: Relay.Clock.utc_now()
           }),
         :ok <- event_data(workflow, request.data),
         :ok <- platform(class),
         {:ok, recipients} <- recipients(scope, request.targets),
         {:ok, payload} <- payload(scope, request, cloudevent),
         {:ok, subtenant} <- subtenant(scope, request.tenant, Map.get(ctx, :subtenant_id)) do
      {:ok,
       %{
         scope: scope,
         event_id: Relay.Id.generate(),
         workflow: workflow,
         category: workflow["definition"]["category"],
         message_class: class,
         request: request,
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

  defp ce_digest(nil), do: nil
  defp ce_digest(event), do: Relay.Ingest.ce_key_digest(event["source"], event["id"])

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
        {:ok, plan} -> {:cont, {:ok, [recipient(plan, index, external_id) | acc]}}
        {:error, %Relay.Error{} = error} -> {:halt, {:error, error}}
        {:error, _reason} -> {:halt, {:error, unavailable("the recipient could not be prepared")}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp recipient(plan, index, external_id),
    do: %{plan: plan, index: index, external_id: external_id}

  defp payload(scope, request, cloudevent) do
    with {:ok, key_id} <- Relay.Tenancy.active_tenant_key(scope, :data),
         {:ok, key} <- Relay.Tenancy.data_key(field(scope, key_id, "data_ct")),
         {:ok, data_ct} <- seal(scope, key_id, "data_ct", request.data, key),
         {:ok, metadata_ct} <- seal(scope, key_id, "metadata_ct", request.metadata, key),
         {:ok, actor_ct} <- seal(scope, key_id, "actor_ct", request.actor, key),
         ce = ce_attributes(cloudevent),
         {:ok, ce_ct} <- seal(scope, key_id, "ce_attributes_ct", ce, key) do
      {:ok,
       %{
         key_id: key_id,
         data_ct: data_ct,
         metadata_ct: metadata_ct,
         actor_ct: actor_ct,
         ce_attributes_ct: ce_ct,
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
  # TN-9
  defp tenant_settings(scope, workflow, steps) do
    category = workflow["definition"]["category"]
    keys = Enum.uniq(Enum.flat_map(steps, &Relay.Ingest.send_mode_keys(category, &1.channel)))

    read = fn _status ->
      %{settings: Relay.Ingest.settings(keys), platform_product: Relay.Ingest.platform_product()}
    end

    with {:ok, tenant} <- Relay.Ingest.in_event_scope(scope, read),
         {:ok, mode} <- Relay.Ingest.installation_send_mode() do
      {:ok, Map.put(tenant, :installation_mode, mode)}
    else
      {:error, _reason} -> {:error, unavailable("the send mode could not be read")}
    end
  end

  # E-10
  # E-11
  # TN-9
  defp message_class(product, declared) do
    case Relay.Access.message_class(product, Map.get(@classes, declared)) do
      nil -> declared
      class -> Atom.to_string(class)
    end
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
      is_test: false,
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
  defp notification(p, event, %{plan: plan, index: index, external_id: external_id}, ctx) do
    with {:ok, recipient_id} <- upsert(plan, index),
         {:ok, result, id, original, mismatch?} <- open_notification(p, event, recipient_id),
         :ok <- created(result, p, id, recipient_id, mismatch?, ctx) do
      duplicate_of = if result == :duplicate, do: original
      {:ok, entry(recipient_id, external_id, id, duplicate_of)}
    end
  end

  defp created(:created, p, id, recipient_id, mismatch?, ctx),
    do: open_deliveries(p, id, Relay.Subscribers.row(recipient_id), mismatch?, ctx)

  defp created(:duplicate, _p, _id, _recipient_id, _mismatch?, _ctx), do: :ok

  defp entry(recipient_id, external_id, notification_id, duplicate_of) do
    Views.accepted_notification(%{
      recipient_kind: "subscriber",
      recipient_id: recipient_id,
      external_id: external_id,
      notification_id: notification_id,
      duplicate_of: duplicate_of
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
      expires_at: p.request.expires_at,
      is_test: false,
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

  defp open_deliveries(p, notification_id, row, mismatch?, ctx) do
    Enum.reduce_while(p.request.steps, :ok, fn step, :ok ->
      case open_delivery(p, notification_id, row, mismatch?, step, ctx) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  # OP-51
  # TN-40
  # API-25
  # API-24
  defp open_delivery(p, notification_id, row, mismatch?, step, ctx) do
    mode =
      Relay.Ingest.send_mode(
        p.request.send_mode,
        p.settings,
        p.category,
        step.channel,
        p.installation_mode
      )

    case decision(step, row, mismatch?, mode) do
      :none ->
        :ok

      {decision, reason, rule} ->
        delivery = %{
          id: Relay.Id.generate(),
          channel: Map.fetch!(@channels, step.channel),
          target_kind: target_kind(step.channel),
          target_key: target_key(step.channel, row["id"]),
          decision: decision,
          decision_reason: reason,
          decision_rule_id: rule,
          deferred_until: nil,
          traceparent: p.traceparent
        }

        case Relay.Ingest.delivery_open(notification_id, delivery) do
          {:opened, id} when decision == :send -> enqueue(p, notification_id, id, ctx)
          {result, _id} when result in [:opened, :exists] -> :ok
          {_other, _id} -> {:error, unavailable("the delivery could not be opened")}
        end
    end
  end

  defp decision(%{skip: {reason, rule}}, _row, _mismatch?, _mode), do: {:skip, reason, rule}
  defp decision(_step, _row, true, _mode), do: {:skip, "scope_mismatch", "tenancy.scope_mismatch"}
  defp decision(_step, _row, _mismatch?, :dry_run), do: :none
  defp decision(_step, _row, _mismatch?, :off), do: {:skip, "send_mode_off", "send_mode.off"}

  defp decision(%{channel: channel}, row, _mismatch?, _mode) do
    case Map.fetch(@address_channels, channel) do
      {:ok, state} when is_map_key(row, state) ->
        if row[state] == "active",
          do: {:send, nil, nil},
          else: {:skip, "no_address", "recipient.no_address"}

      _ ->
        {:send, nil, nil}
    end
  end

  defp target_kind(channel) when channel in ~w(email sms voice whatsapp), do: :address
  defp target_kind("in_app"), do: :inbox
  defp target_kind(channel) when channel in ~w(push web_push), do: :device
  defp target_kind(_channel), do: :endpoint

  defp target_key(channel, recipient_id) do
    :crypto.hash(:sha256, Relay.Canonical.encode!(["target", channel, {:bytes, recipient_id}]))
  end

  # T-15
  # TN-40 (1)
  defp enqueue(p, notification_id, delivery_id, _ctx) do
    case KillSwitch.at_acceptance(delivery_id) do
      {:paused, _rule_id} ->
        :ok

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
          scheduled_at: p.request.send_at
        }

        case Relay.Platform.enqueue_job(job) do
          {:ok, _queued} -> :ok
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
