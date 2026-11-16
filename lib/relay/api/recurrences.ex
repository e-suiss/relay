defmodule Relay.Api.Recurrences do
  @moduledoc """
  Recurrence rules on the server API (C-52, WF-48, WF-49, WF-61) and the firing of their occurrences.

  `POST /v1/recurrences` defines a rule that sends a published workflow to one subscriber (`subscriber_id`, the tenant's external id) or to one topic (`topic`) on the occurrences of an RRULE subset from a local `dtstart` (`Relay.Workflow.RRule`). The request is checked outside any transaction: the workflow must be published, `data` must match its event schema and fit `event.max_data_bytes`, the rule must have an occurrence after now. `data` is sealed under the subscriber's `recipient_profile` key, so erasing the subscriber shreds it, and a topic rule's under the tenant data key; it is never shown again. The rule, its first occurrence and its timer job commit with the idempotency claim; a tenant environment holds at most `recurrence.max_active_per_environment` active rules (`422 recurrence_limit_reached`). `POST /v1/recurrences/{id}/cancel` stops every later occurrence; nothing is deleted.

  An occurrence is fired by its timer (`Relay.Api.Recurrences.Timer`), by the virtual clock of a `test` scope (`run_due/1`) or by the missed-timer sweep (`Relay.Api.Recurrences.Sweep`). The due occurrence goes through the same path as `POST /v1/events` (`Relay.Api.Events.prepare/3` and `accept/2`) with the workflow version published at that moment (WF-49): the subscriber is the event's one recipient, the idempotency key is the rule and the occurrence instant (`RECURRENCE` endpoint) and the dedup key is `recurrence:<rule>:<instant>`, so a timer that runs twice opens one event. The occurrence record, the rule's next occurrence and its next timer commit in the event's transaction. Missed occurrences are recorded with `recurrence.missed` (WF-61). A topic rule's occurrence is an event to the topic, which the send path expands into the topic's frozen audience (WF-52, `Relay.Topics.expand/2`); an audience without subscribers is accepted and recorded with `audience.no_subscribers` (WF-53), and an audience above the event's recipient limit is recorded skipped with `recurrence.audience_too_large` (API-35). While the tenant is suspended the timer waits and fires again every five minutes, so after the suspension ends the missed rule applies (TN-10). An occurrence the send path refuses (an unpublished or archived workflow, data that no longer matches the schema, an exhausted quota) is recorded `failed` with the error code, and the rule goes on. A retryable refusal (overload, an unavailable store) retries the timer. A rule whose subscriber was erased is cancelled with `subject_erasure` at its next timer (OP-24).
  """

  alias Relay.Api.ErrorCatalog
  alias Relay.Api.Events
  alias Relay.Api.Idempotency
  alias Relay.Api.Page
  alias Relay.Api.Recurrences.Timer
  alias Relay.Api.Schema
  alias Relay.Api.Views
  alias Relay.Scope

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  @prefix "rec"
  @endpoint "RECURRENCE"
  @data_bytes Relay.Limits.fetch!(["event", "max_data_bytes"])
  @due_batch 100
  @sweep_min_age_ms 60_000
  @audience_rule "recurrence.audience_too_large"
  @missed_rule "recurrence.missed"
  @suspended_snooze_s 300
  @lanes [:l1, :l2, :l3]

  @doc "The external identifier prefix of a recurrence rule."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  # WF-48
  # WF-61
  # API-27
  @doc "Checks a create request outside any transaction and prepares the rule: its target, workflow, first occurrence, timer and sealed data."
  @spec prepare(Scope.t(), map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def prepare(%Scope{} = scope, body) do
    id = Relay.Id.generate()
    data = Map.get(body, "data", %{})

    with {:ok, target} <- target(scope, body),
         {:ok, workflow} <- workflow(scope, body["workflow"]),
         :ok <- data_size(data),
         :ok <- event_data(workflow, data),
         {:ok, planned} <-
           Relay.Workflow.plan_recurrence(scope, %{
             id: id,
             rrule: body["rrule"],
             dtstart: body["dtstart"],
             timezone: body["timezone"],
             target_kind: target.kind,
             recipient_id: target.recipient_id,
             now: Relay.Clock.business_now(scope)
           }),
         {:ok, sealed} <- seal(scope, target, data) do
      {:ok,
       %{
         subscriber_id: target.external_id,
         attrs: %{
           id: id,
           workflow_id: workflow["workflow_id"],
           workflow_key: body["workflow"],
           target_kind: target.kind,
           recipient_id: target.recipient_id,
           topic_key: target.topic,
           rrule: planned.rrule,
           dtstart: planned.dtstart,
           timezone: planned.timezone,
           data_ct: sealed.data_ct,
           data_key_id: sealed.data_key_id,
           next_at: planned.next.at,
           next_ordinal: planned.next.ordinal,
           next_zone: planned.next.zone,
           fire_at: planned.next.fire_at
         }
       }}
    end
  end

  # WF-48
  # WF-49
  # WF-61
  @doc "Records a prepared rule and queues its timer inside the request's transaction; `201` with its view."
  @spec create(Scope.t(), map(), Relay.Actor.t()) :: answer()
  def create(%Scope{} = scope, %{attrs: attrs} = prepared, actor) do
    digest = digest(scope, "recurrence.created", attrs.id)

    case Relay.Workflow.create_recurrence(attrs, digest, actor) do
      :created ->
        :ok = Relay.Workflow.queue_job!(timer(scope, attrs.id, attrs.fire_at))
        row = Relay.Workflow.view_recurrence(attrs.id)
        location = [{"location", "/v1/recurrences/" <> Views.id(@prefix, attrs.id)}]
        {:ok, {201, location, view(row, prepared.subscriber_id)}}

      :limit_reached ->
        {:error, limit_reached()}
    end
  end

  # WF-48
  @doc "Reads a rule in its own read transaction, with the subscriber's external id decrypted."
  @spec get(Scope.t(), Relay.Id.t()) :: answer()
  def get(%Scope{} = scope, id) do
    with {:ok, row} <- found(Relay.Workflow.get_recurrence(scope, id)),
         {:ok, external} <- external_ids(scope, [row]) do
      {:ok, {200, [], view(row, Map.get(external, row["recipient_id"]))}}
    end
  end

  # API-56
  @doc "Lists rules newest first, in pages."
  @spec list(Scope.t(), Relay.Api.Pagination.page(), String.t()) :: answer()
  def list(%Scope{} = scope, page, endpoint) do
    position = &{&1["created_at"], &1["id"]}

    with {:ok, rows} <- read(Relay.Workflow.list_recurrences(scope, page.cursor, page.limit)),
         {:ok, external} <- external_ids(scope, rows),
         render = &view(&1, Map.get(external, &1["recipient_id"])),
         {:ok, body} <- Page.envelope(rows, page, scope, endpoint, render, position) do
      {:ok, {200, [], body}}
    end
  end

  # WF-49
  @doc "Reads the rule a cancel names outside any transaction: `{:ok, subscriber_external_id}` for a known rule."
  @spec prepare_cancel(Scope.t(), Relay.Id.t()) ::
          {:ok, String.t() | nil} | {:error, Relay.Error.t()}
  def prepare_cancel(%Scope{} = scope, id) do
    with {:ok, row} <- found(Relay.Workflow.get_recurrence(scope, id)),
         {:ok, external} <- external_ids(scope, [row]) do
      {:ok, Map.get(external, row["recipient_id"])}
    end
  end

  # WF-49
  @doc "Cancels an active rule inside the request's transaction; `200` with its view, `409 recurrence_closed` for a rule that is over."
  @spec cancel(Scope.t(), Relay.Id.t(), String.t() | nil, Relay.Actor.t()) :: answer()
  def cancel(%Scope{} = scope, id, subscriber_id, actor) do
    digest = digest(scope, "recurrence.cancelled", id)

    case Relay.Workflow.cancel_recurrence(id, "request", digest, actor) do
      :cancelled ->
        {:ok, {200, [], view(Relay.Workflow.view_recurrence(id), subscriber_id)}}

      :closed ->
        {:error, Relay.Error.new(:recurrence_closed, "the rule is completed or cancelled")}

      :not_found ->
        {:error, not_found()}
    end
  end

  # WF-48
  @doc "The API view of a rule row with its last occurrence."
  @spec view(map(), String.t() | nil) :: map()
  def view(row, subscriber_id) do
    %{
      "object" => "recurrence",
      "id" => Views.id(@prefix, row["id"]),
      "workflow" => %{"key" => row["workflow_key"]},
      "subscriber_id" => subscriber_id,
      "topic" => row["topic_key"],
      "rrule" => row["rrule"],
      "dtstart" => row["dtstart"],
      "timezone" => row["timezone"],
      "state" => row["state"],
      "next_occurrence_at" => row["next_at"],
      "next_occurrence_timezone" => row["next_zone"],
      "occurrence_count" => row["occurrence_count"],
      "last_occurrence" => last(row["last_occurrence"]),
      "cancel_reason" => row["cancel_reason"],
      "cancelled_at" => row["cancelled_at"],
      "completed_at" => row["completed_at"],
      "created_at" => row["created_at"],
      "updated_at" => row["updated_at"]
    }
  end

  defp last(nil), do: nil

  defp last(o) do
    %{
      "occurrence_at" => o["occurrence_at"],
      "outcome" => o["outcome"],
      "rule_id" => o["rule_id"],
      "error_code" => o["error_code"],
      "event_id" => Views.id("evt", o["event_id"])
    }
  end

  @doc "The error of an unknown rule."
  @spec not_found() :: Relay.Error.t()
  def not_found, do: Relay.Error.new(:recurrence_not_found, "no recurrence rule has this id")

  # WF-49
  # WF-61
  # WF-43
  @doc "Fires what a rule has due in business time: the last due occurrence through the send path, the missed ones as records, then its next occurrence and timer. `:ok` when there is nothing (more) to do; an error retries the timer and `{:snooze, seconds}` waits, as for a suspended tenant."
  @spec fire(Scope.t(), Relay.Id.t()) :: :ok | {:snooze, pos_integer()} | {:error, term()}
  def fire(%Scope{} = scope, id) do
    case Relay.Workflow.due_recurrence(scope, id, Relay.Clock.business_now(scope)) do
      {:ok, :inactive} -> :ok
      {:ok, :not_due} -> :ok
      {:ok, {:recipient_erased, _row}} -> erased(scope, id)
      {:ok, {:due, due}} -> run(scope, due)
      {:error, error} -> {:error, error}
    end
  end

  # WF-43
  # TN-8
  @doc "Fires every rule of a scope whose timer is due in business time; used by the missed-timer sweep and the virtual clock tick."
  @spec run_due(Scope.t()) :: :ok | {:error, term()}
  def run_due(%Scope{} = scope) do
    case Relay.Workflow.due_recurrences(scope, Relay.Clock.business_now(scope), @due_batch) do
      {:ok, ids} ->
        Enum.each(ids, &fire(scope, &1))
        if length(ids) == @due_batch, do: run_due(scope), else: :ok

      {:error, _reason} = error ->
        error
    end
  end

  # WF-43
  @doc "Fires the rules of every scope with a timer due more than a minute ago and returns how many scopes were visited."
  @spec sweep(pos_integer()) :: non_neg_integer()
  def sweep(limit \\ 100) do
    @sweep_min_age_ms
    |> Relay.Workflow.recurrence_due_scopes(limit)
    |> Enum.count(fn {tenant_id, environment} ->
      with {:ok, scope} <- Scope.new(tenant_id, environment),
           :ok <- run_due(scope) do
        true
      else
        _ -> false
      end
    end)
  end

  # WF-43
  @doc "The timer job of a rule's occurrence, scheduled for its jittered instant in wall-clock time."
  @spec timer(Scope.t(), Relay.Id.t(), DateTime.t()) :: Ecto.Changeset.t()
  def timer(%Scope{} = scope, id, fire_at) do
    scope
    |> Scope.to_job_args()
    |> Map.put("recurrence_id", Relay.Id.to_string(id))
    |> Timer.new(scheduled_at: Relay.Clock.wall_time(scope, fire_at))
  end

  defp run(scope, %{send: nil} = due), do: record(scope, due, [])

  defp run(scope, due) do
    case event_body(scope, due) do
      {:ok, body} -> deliver(scope, due, body)
      :erased -> erased(scope, due.row["id"])
      {:error, error} -> refused(scope, due, error)
    end
  end

  defp deliver(scope, due, body) do
    ctx = context(scope)
    key = occurrence_key(due)

    with {:ok, prepared} <- Events.prepare(ctx, body, dedup_key: "recurrence:" <> key),
         :ok <- admission(prepared) do
      work = fn _status -> accept(scope, prepared, ctx, due) end

      case Idempotency.run(scope, @endpoint, key, Jason.encode!(body), work) do
        {:ok, _outcome} -> :ok
        {:error, %Relay.Error{code: :resource_conflict}} -> :ok
        {:error, error} -> refused(scope, due, error)
      end
    else
      {:error, error} -> refused(scope, due, error)
    end
  end

  defp accept(scope, prepared, ctx, due) do
    with {:ok, answer} <- Events.accept(prepared, ctx) do
      sent = Map.merge(due.send, %{outcome: "sent", event_id: prepared.event_id})
      id = due.row["id"]

      case Relay.Workflow.fire_recurrence(id, due.row["next_at"], missed(due) ++ [sent], due.next) do
        :advanced ->
          :ok = Relay.Workflow.queue_job!(timer(scope, id, due.next.fire_at))
          {:ok, {202, [], Jason.encode!(answer)}}

        :completed ->
          {:ok, {202, [], Jason.encode!(answer)}}

        _stale_or_missing ->
          {:error, Relay.Error.new(:resource_conflict, "the rule moved on")}
      end
    end
  end

  # TN-10
  defp refused(_scope, _due, %Relay.Error{code: :auth_tenant_suspended}),
    do: {:snooze, @suspended_snooze_s}

  # WF-52
  # API-35
  defp refused(scope, due, %Relay.Error{code: :audience_too_large}),
    do: record(scope, due, [skipped(due.send, @audience_rule)])

  defp refused(scope, due, %Relay.Error{code: code} = error) do
    case ErrorCatalog.fetch(code) do
      {:ok, %{retryable: false}} ->
        record(scope, due, [
          Map.merge(due.send, %{outcome: "failed", error_code: Atom.to_string(code)})
        ])

      _retryable_or_unknown ->
        {:error, error}
    end
  end

  defp record(scope, due, extra) do
    id = due.row["id"]
    job = &timer(scope, id, &1.fire_at)
    occurrences = missed(due) ++ extra

    case Relay.Workflow.record_recurrence(
           scope,
           id,
           due.row["next_at"],
           occurrences,
           due.next,
           job
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp missed(due), do: Enum.map(due.missed, &skipped(&1, @missed_rule, "missed"))

  defp skipped(occurrence, rule_id, outcome \\ "skipped"),
    do: Map.merge(occurrence, %{outcome: outcome, rule_id: rule_id})

  # OP-24
  defp erased(scope, id) do
    {:ok, actor} = Relay.Actor.new(:system, "relay:recurrence", "relay")
    digest = digest(scope, "recurrence.cancelled", id)

    case Relay.Workflow.cancel_recurrence(scope, id, "subject_erasure", digest, actor) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp occurrence_key(due),
    do:
      Views.id(@prefix, due.row["id"]) <>
        "@" <> Relay.Workflow.recurrence_instant(due.send.at)

  defp event_body(scope, due) do
    row = due.row

    with {:ok, target} <- recipient(scope, row),
         {:ok, data} <- open(scope, row) do
      {:ok, %{"workflow" => row["workflow_key"], "to" => [target], "data" => data}}
    end
  end

  # WF-48
  # WF-52
  defp recipient(_scope, %{"target_kind" => "topic", "topic_key" => key}),
    do: {:ok, %{"topic" => key}}

  defp recipient(scope, %{"recipient_id" => recipient_id}) do
    case Relay.Subscribers.external_id(scope, recipient_id) do
      {:ok, nil} -> :erased
      {:ok, external_id} -> {:ok, external_id}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp open(_scope, %{"data_ct" => nil}), do: {:ok, %{}}

  defp open(scope, row) do
    with {:ok, plain} <- Relay.Tenancy.decrypt_field(data_field(scope, row), row["data_ct"]),
         {:ok, data} <- Jason.decode(Relay.Redacted.expose(plain)) do
      {:ok, data}
    else
      _other -> {:error, unavailable()}
    end
  end

  defp context(scope) do
    {:ok, actor} = Relay.Actor.new(:system, "relay:recurrence", "relay")
    %{scope: scope, actor: actor, api_client_id: nil, subtenant_id: nil, traceparent: nil}
  end

  # T-35
  # API-51
  defp admission(prepared) do
    {class, channels} = Events.admission(prepared)

    input = %{
      message_class: class,
      channels: channels,
      shed: Map.new(@lanes, &{&1, Relay.Platform.load_shed_engaged?(&1)}),
      breaker_open: MapSet.new(),
      lane_capacity: Relay.Platform.lane_capacity()
    }

    case Relay.Platform.admit(input) do
      :admit -> :ok
      {:reject, _reason} -> {:error, Relay.Error.new(:service_unavailable, "Relay is overloaded")}
    end
  end

  defp target(scope, %{"subscriber_id" => external_id} = body)
       when is_binary(external_id) and not is_map_key(body, "topic") do
    case Relay.Subscribers.locate(scope, external_id) do
      {:ok, nil} ->
        {:error, Relay.Error.new(:subscriber_not_found, "no subscriber has this id")}

      {:ok, recipient_id} ->
        {:ok,
         %{kind: "subscriber", recipient_id: recipient_id, external_id: external_id, topic: nil}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  defp target(_scope, %{"topic" => topic} = body)
       when is_binary(topic) and not is_map_key(body, "subscriber_id"),
       do: {:ok, %{kind: "topic", recipient_id: nil, external_id: nil, topic: topic}}

  defp target(_scope, %{"subscriber_id" => _, "topic" => _}),
    do: field("/topic", "not_allowed", "a rule targets a subscriber or a topic, not both")

  defp target(_scope, _body),
    do: field("/subscriber_id", "required", "a rule targets a subscriber or a topic")

  defp workflow(scope, key) do
    case Relay.Workflow.resolve_published(scope, key) do
      {:ok, {:ok, workflow}} ->
        {:ok, workflow}

      {:ok, :not_found} ->
        {:error, Relay.Error.new(:workflow_not_found, "no workflow has this key")}

      {:ok, :not_published} ->
        {:error,
         Relay.Error.new(:workflow_not_published, "the workflow has no published version")}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  defp data_size(data) do
    if byte_size(Jason.encode!(data)) > @data_bytes,
      do: field("/data", "too_long", "data is at most #{@data_bytes} bytes"),
      else: :ok
  end

  # API-27
  defp event_data(workflow, data) do
    with {:ok, root} <- Relay.Workflow.event_schema(workflow["event_schema"]),
         {:error, error} <- Schema.validate(root, data) do
      errors = Enum.map(error.details.errors, &%{&1 | pointer: "/data" <> &1.pointer})

      {:error,
       Relay.Error.new(:validation_failed, "data does not match the event schema", %{
         errors: errors
       })}
    else
      _valid_or_no_schema -> :ok
    end
  end

  defp seal(_scope, _target, data) when data == %{}, do: {:ok, %{data_ct: nil, data_key_id: nil}}

  defp seal(scope, %{kind: "subscriber"} = target, data) do
    field = subject_field(scope, target.recipient_id)

    case Relay.Tenancy.encrypt_field(field, Jason.encode!(data)) do
      {:ok, ct} -> {:ok, %{data_ct: ct, data_key_id: nil}}
      {:error, _error} -> {:error, unavailable()}
    end
  end

  defp seal(scope, %{kind: "topic"}, data) do
    with {:ok, key_id} <- Relay.Tenancy.active_tenant_key(scope, :data),
         {:ok, ct} <-
           Relay.Tenancy.encrypt_field(tenant_field(scope, key_id), Jason.encode!(data)) do
      {:ok, %{data_ct: ct, data_key_id: key_id}}
    else
      {:error, _error} -> {:error, unavailable()}
    end
  end

  defp data_field(scope, %{"target_kind" => "subscriber", "recipient_id" => recipient_id}),
    do: subject_field(scope, recipient_id)

  defp data_field(scope, %{"data_key_id" => key_id}), do: tenant_field(scope, key_id)

  defp subject_field(scope, recipient_id) do
    %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: recipient_id,
      retention_class: :recipient_profile,
      table: "recurrences",
      column: "data_ct"
    }
  end

  defp tenant_field(scope, key_id) do
    %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: nil,
      retention_class: :notification_content,
      table: "recurrences",
      column: "data_ct",
      key_id: key_id
    }
  end

  defp external_ids(scope, rows) do
    ids = for %{"recipient_id" => <<_::128>> = id} <- rows, uniq: true, do: id

    case Relay.Subscribers.external_ids(scope, ids) do
      {:ok, found} -> {:ok, found}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp found({:ok, nil}), do: {:error, not_found()}
  defp found({:ok, row}), do: {:ok, row}
  defp found({:error, _reason}), do: {:error, unavailable()}

  defp read({:ok, value}), do: {:ok, value}
  defp read({:error, _reason}), do: {:error, unavailable()}

  defp limit_reached do
    limit = Relay.Limits.fetch!(["recurrence", "max_active_per_environment"])

    Relay.Error.new(
      :recurrence_limit_reached,
      "the tenant environment holds #{limit} active recurrence rules",
      %{limit: limit}
    )
  end

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})

  defp digest(scope, action, id) do
    environment = Atom.to_string(scope.environment)
    parts = [action, {:bytes, scope.tenant_id}, environment, Relay.Id.to_string(id)]
    :crypto.hash(:sha256, Relay.Canonical.encode!(parts))
  end

  defp field(pointer, code, detail) do
    {:error,
     Relay.Error.new(:validation_failed, detail, %{
       errors: [%{pointer: pointer, code: code, detail: detail}]
     })}
  end
end
