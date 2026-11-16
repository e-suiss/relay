defmodule Relay.Webhooks.Engine do
  @moduledoc """
  One delivery attempt of a message, from claim to settlement (WH-10, WH-22, WH-23, WH-27, WH-32, WH-35, WH-36, WH-38).

  An attempt claims its message with a lock, so that at most one attempt of a message runs at a time, and asks the endpoint's circuit breaker; a rejected message is held and waits for the release. The claimed message then needs a slot of the endpoint's concurrency and one delivery of its rate: without either it is given back with a later attempt time and its attempt counter untouched. The envelope body is built from the stored event and the snapshot allow-list of the endpoint version the message is pinned to, never from a request's API version (API-55), signed outside any transaction with a new `webhook-timestamp`, and handed to the destination of the endpoint's kind with the limits of the contract.

  The result is classified by `Relay.Webhooks.Outcome` and settled in one transaction: the attempt log row, the message's next state, its next job, the endpoint's health and breaker, the operational events and the jobs of their e-mails. A resend (`manual`) locks the message without changing its state: a success delivers it and cancels its waiting attempts, a failure leaves its state and schedule as they were. A test message is attempted once and touches neither the endpoint's health nor the operational events.

  Telemetry: `[:relay, :webhooks, :attempt]` with `count` and `duration_ms`, tagged with the `result`, the `trigger` and whether it was the message's `first` attempt.
  """

  alias Relay.Scope
  alias Relay.Webhooks.Destination
  alias Relay.Webhooks.DestinationEvents
  alias Relay.Webhooks.EngineStore
  alias Relay.Webhooks.Envelope
  alias Relay.Webhooks.Fanout
  alias Relay.Webhooks.Health
  alias Relay.Webhooks.NoticeWorker
  alias Relay.Webhooks.Outcome
  alias Relay.Webhooks.Profile
  alias Relay.Webhooks.RetrySchedule
  alias Relay.Webhooks.Settings

  @lock_extra_ms 40_000
  @response_field {"webhook_attempts", "response_ct"}

  @type result :: :done | {:retry_in, pos_integer()} | {:attempted, atom()}

  # WH-32 (4)
  # WH-38
  @doc "Makes one attempt of a message. Options: `:manual` for a resend, `:holder`, the name the concurrency slot is held under, and `:clock`, the function the attempt reads the time from (`Relay.Clock.utc_now/0`). Returns `{:attempted, state}` with the message's state after it, `:done` when there was nothing to attempt, or `{:retry_in, seconds}` while another attempt holds the message."
  @spec attempt(Scope.t(), Relay.Id.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def attempt(%Scope{} = scope, message_id, opts \\ []) do
    manual? = Keyword.get(opts, :manual, false)
    holder = Keyword.get(opts, :holder, "whm:" <> Relay.Id.to_string(message_id))
    clock = Keyword.get(opts, :clock, &Relay.Clock.utc_now/0)
    token = Relay.Id.generate()
    work = fn _status -> claim(message_id, token, manual?, clock.()) end

    case EngineStore.in_scope(scope, work) do
      {:ok, {:run, delivery, decision}} ->
        run = %{scope: scope, delivery: delivery, token: token, decision: decision}
        {:ok, limited(Map.merge(run, %{manual?: manual?, clock: clock}), holder)}

      {:ok, other} ->
        {:ok, other}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp claim(message_id, token, manual?, now) do
    until = DateTime.add(now, Settings.request().total_ms + @lock_extra_ms, :millisecond)

    case EngineStore.claim(message_id, token, until, manual?, now) do
      {:claimed, _at} -> admitted(EngineStore.delivery(message_id), token, manual?, now)
      {:locked, at} -> {:retry_in, max(DateTime.diff(at, now, :second), 1)}
      {:window_exceeded, _at} -> window_exceeded(EngineStore.delivery(message_id))
      {_other, _at} -> :done
    end
  end

  # WH-35
  defp admitted(%{message: %{"origin" => "test"}} = delivery, _token, _manual?, _now),
    do: {:run, delivery, :allow}

  defp admitted(delivery, _token, true, _now), do: {:run, delivery, :allow}

  defp admitted(%{message: message, endpoint: endpoint} = delivery, token, false, now) do
    health = EngineStore.health_lock(endpoint["id"])

    case Health.admit(health, now, Settings.health()) do
      {{:reject, wait_ms}, _unchanged} ->
        :parked = EngineStore.park(message["id"], token, "held", "breaker_open", nil, now)
        at = DateTime.add(now, wait_ms, :millisecond)
        :ok = Fanout.release_job(endpoint["id"], "breaker_open", at)
        :done

      {decision, changed} ->
        if changed, do: EngineStore.health_save(endpoint["id"], Health.columns(changed), now)
        {:run, delivery, decision}
    end
  end

  # WH-28 (2)
  defp window_exceeded(%{message: message, endpoint: endpoint, event: event}) do
    alarm(endpoint["id"], webhook_id(event), message["id"])
    :done
  end

  # WH-28 (2)
  # WH-34
  @doc "Appends the `webhook.window_exceeded` alarm of a message whose window ended and queues its e-mail, inside the caller's scoped transaction."
  @spec alarm(Relay.Id.t(), String.t(), Relay.Id.t()) :: :ok
  def alarm(endpoint_id, event_id, message_id) do
    payload = %{"endpoint_id" => external(endpoint_id), "event_id" => event_id}
    :appended = EngineStore.outbox_append("webhook.window_exceeded", endpoint_id, payload)
    notice("window_exceeded", endpoint_id, message_id)
  end

  # WH-38
  defp limited(%{manual?: true} = run, _holder), do: {:attempted, deliver(run)}

  defp limited(%{scope: scope, delivery: %{endpoint: endpoint}} = run, holder) do
    defaults = Settings.isolation()
    runtime = Settings.runtime()
    rate = endpoint["rate_per_second"] || defaults.rate
    limit = endpoint["max_concurrency"] || defaults.concurrency

    with :allow <- runtime.rate(scope, endpoint["id"], rate),
         {:ok, state} <-
           runtime.with_slot(scope, endpoint["id"], limit, holder, fn -> deliver(run) end) do
      {:attempted, state}
    else
      {:deny, wait_ms} -> postponed(run, wait_ms)
      {:full, wait_ms} -> postponed(run, wait_ms)
    end
  end

  # WH-38
  # WH-28
  defp postponed(%{scope: scope, delivery: %{message: message}, token: token} = run, wait_ms) do
    work = fn _status ->
      now = run.clock.()
      at = DateTime.add(now, max(wait_ms, 1000), :millisecond)
      state = if message["attempt_count"] == 0, do: "pending", else: "scheduled"

      with :parked <- EngineStore.park(message["id"], token, state, nil, at, now),
           do: Fanout.attempt_job(message["id"], at)
    end

    _ = EngineStore.in_scope(scope, work)
    :done
  end

  defp deliver(%{scope: scope, delivery: delivery} = run) do
    started = run.clock.()
    clock = Relay.Clock.monotonic_ms()

    {result, sent} =
      case prepared(scope, delivery, started) do
        {:ok, sent} -> {send_out(scope, delivery.endpoint, sent), sent}
        {:error, outcome, sent} -> {outcome, sent}
      end

    now = run.clock.()
    outcome = outcome(result, now)

    attempt = %{
      started_at: started,
      duration_ms: duration(result, clock),
      sent: sent,
      answer: answer(result),
      outcome: outcome
    }

    settle(run, attempt, now)
  end

  defp outcome(%Outcome{} = outcome, _now), do: outcome
  defp outcome(result, now), do: Outcome.classify(result, now)

  defp duration({_tag, %{duration_ms: ms}}, _clock) when is_integer(ms), do: ms
  defp duration(_result, clock), do: max(Relay.Clock.monotonic_ms() - clock, 0)

  defp answer({_tag, %{} = answer}), do: answer
  defp answer(_outcome), do: %{}

  # WH-7
  # WH-8
  # WH-12
  # WH-29
  # API-55
  defp prepared(scope, %{message: message, endpoint: endpoint} = delivery, now) do
    with {:ok, envelope} <- envelope(scope, delivery),
         body = Envelope.encode(envelope),
         sent = %{body_digest: :crypto.hash(:sha256, body), signature: nil, timestamp: nil},
         :ok <- sized(body, sent),
         {:ok, headers, sent} <- signed(scope, endpoint, envelope.id, body, sent, now) do
      attempt_no = message["total_attempt_count"] + 1
      {:ok, Map.put(sent, :prepared, Destination.prepare(envelope, body, headers, attempt_no))}
    end
  end

  defp sized(body, sent) do
    case Envelope.check_size(body, Settings.payload_max()) do
      :ok -> :ok
      {:error, _too_large} -> {:error, dead(:payload_too_large), sent}
    end
  end

  defp dead(reason), do: %Outcome{result: :dead_lettered, reason: reason}

  @doc "The `webhook-id` of a stored event: the external identifier of the outbox event behind it, or the test event's own."
  @spec webhook_id(map()) :: String.t()
  def webhook_id(%{"origin" => "test", "id" => id}), do: "test_" <> Relay.Id.to_string(id)
  def webhook_id(%{"id" => id}), do: Relay.ExternalId.encode("oev", id)

  defp envelope(scope, %{event: event, version: version}) do
    case data(scope, event, version["snapshot"]) do
      {:ok, data} -> enveloped(scope, event, data)
      {:error, :erased} -> {:error, dead(:payload_erased), blank()}
      {:error, :unavailable} -> {:error, unavailable("payload_unavailable"), blank()}
    end
  end

  # WH-13
  # WH-45 (3)
  defp data(scope, %{"use_kind" => "destination", "origin" => origin} = event, allow_list)
       when origin != "test",
       do: DestinationEvents.payload(scope, event, allow_list)

  defp data(scope, event, allow_list), do: {:ok, snapshot(scope, event, allow_list)}

  # WH-8
  # WH-11
  @doc "The thin envelope of a stored event of Relay's own, as an endpoint without a snapshot receives it; `nil` when it cannot be built. Runs outside any transaction."
  @spec thin_envelope(Scope.t(), map()) :: Envelope.t() | nil
  def thin_envelope(%Scope{} = scope, %{"use_kind" => "relay_events"} = event) do
    case enveloped(scope, event, event["payload"] || %{}) do
      {:ok, envelope} -> envelope
      {:error, _outcome, _sent} -> nil
    end
  end

  defp enveloped(scope, event, data) do
    source = event["source"] || Settings.source()

    fields = %{
      id: webhook_id(event),
      source: source,
      type: event["event_type"],
      time: event["occurred_at"],
      subject: event["subject"],
      dataschema: "#{source}/v1/event_schemas/#{event["event_type"]}/#{event["schema_version"]}",
      seq: event["seq"],
      traceparent: event["traceparent"],
      environment: scope.environment,
      data: data,
      extensions: extensions(scope, event, data)
    }

    case Envelope.new(usage(event), fields) do
      {:ok, envelope} -> {:ok, envelope}
      {:error, _invalid} -> {:error, dead(:event_invalid), blank()}
    end
  end

  defp blank, do: %{body_digest: :crypto.hash(:sha256, ""), signature: nil, timestamp: nil}

  defp usage(%{"use_kind" => "destination"}), do: :destination
  defp usage(_event), do: :relay_events

  # WH-12
  defp snapshot(_scope, %{"payload" => nil}, _allow_list), do: %{}
  defp snapshot(_scope, %{"payload" => payload}, []), do: payload

  defp snapshot(scope, %{"origin" => "outbox", "payload" => payload} = event, allow_list) do
    case Settings.runtime().event_source(scope, event["id"], event["occurred_at"]) do
      %{} = source -> Envelope.snapshot(payload, catalogued(event, source), allow_list)
      nil -> payload
    end
  end

  defp snapshot(_scope, %{"payload" => payload}, _allow_list), do: payload

  # WH-53
  defp catalogued(%{"event_type" => type}, source) do
    case Relay.EventCatalog.fields(type) do
      {:ok, fields} -> Map.take(source, fields)
      :error -> %{}
    end
  end

  # WH-8 (2)
  # E-85
  defp extensions(_scope, %{"use_kind" => "destination"}, _data), do: %{}

  defp extensions(scope, _event, data) do
    read = fn _status ->
      EngineStore.envelope_context(internal(data["tenant"], "stn"), notification(data))
    end

    case EngineStore.in_scope(scope, read) do
      {:ok, row} ->
        [
          {"accesstenant", row["access_tenant_id"]},
          {"accessorganization", row["access_organization_id"]},
          {"correlationid", row["correlation_id"]}
        ]
        |> Enum.filter(fn {_name, value} -> is_binary(value) and value != "" end)
        |> Map.new()

      {:error, _reason} ->
        %{}
    end
  end

  defp notification(data), do: internal(data["notification_id"], "ntf")

  defp internal(text, prefix) when is_binary(text) do
    case Relay.ExternalId.decode(text, [prefix]) do
      {:ok, id} -> id
      {:error, _error} -> nil
    end
  end

  defp internal(_other, _prefix), do: nil

  # WH-4
  # WH-7 (1)
  defp signed(scope, %{"kind" => "https", "id" => id}, webhook_id, body, sent, now) do
    timestamp = DateTime.to_unix(now)

    with {:ok, [_key | _rest] = keys} <- Relay.Webhooks.signing_keys(scope, id),
         {:ok, tokens} <-
           Relay.Webhooks.signature_tokens(scope, keys, webhook_id, timestamp, body) do
      sent = %{sent | signature: Profile.signature_header(tokens), timestamp: timestamp}
      {:ok, Profile.headers(webhook_id, timestamp, tokens), sent}
    else
      _unavailable -> {:error, unavailable("signing_key_unavailable"), sent}
    end
  end

  defp signed(_scope, _endpoint, _webhook_id, _body, sent, _now), do: {:ok, [], sent}

  defp unavailable(reason),
    do: {:error, %{class: :credentials, reason: reason, duration_ms: 0, address: nil}}

  # WH-17
  # WH-24
  # WH-19
  defp send_out(scope, %{"kind" => kind} = endpoint, %{prepared: prepared}) do
    with {:ok, module} <- Settings.destination(kind),
         {:ok, config} <- destination_config(scope, module, endpoint) do
      :ok = Relay.NetworkGuard.check!(:http)
      module.deliver(config, prepared, options())
    else
      :error -> {:error, unattempted(:invalid, "kind_unavailable")}
      {:error, failure} -> {:error, failure}
    end
  end

  defp options do
    limits = Settings.request()
    extra = Settings.destination_limits()

    [
      policy: Relay.Webhooks.egress_policy(),
      resolver: Relay.Webhooks.resolver(),
      connect_timeout_ms: limits.connect_ms,
      total_timeout_ms: limits.total_ms,
      max_response_bytes: limits.response_max,
      dns_timeout_ms: limits.connect_ms,
      max_frame_bytes: extra.max_frame_bytes,
      ack_timeout_ms: extra.ack_timeout_ms,
      max_scram_iterations: extra.max_scram_iterations,
      assertion_ttl_s: extra.assertion_ttl_s,
      credential_ttl_s: extra.credential_ttl_s,
      token_cache: &uncached/1
    ]
    |> Keyword.merge(Settings.destination_options())
  end

  defp uncached(fetch) do
    case fetch.() do
      {:ok, token, _lifetime} -> {:ok, token}
      {:error, failure} -> {:error, failure}
    end
  end

  defp unattempted(class, reason),
    do: %{class: class, reason: reason, duration_ms: 0, address: nil}

  # WH-21
  defp destination_config(_scope, _module, %{"kind" => "s3"}),
    do: {:error, unattempted(:unavailable, "object_batch_unavailable")}

  defp destination_config(_scope, _module, %{"kind" => "https", "url" => url} = endpoint) do
    case Map.get(endpoint["destination"], "auth", "none") do
      "none" -> {:ok, %{url: url}}
      _other -> {:error, unattempted(:credentials, "destination_auth_unavailable")}
    end
  end

  # WH-19
  defp destination_config(scope, module, %{"destination" => destination} = endpoint) do
    _ = Code.ensure_loaded(module)

    config =
      for {key, value} <- destination, atom = field(key), atom != nil, into: %{} do
        {atom, value}
      end

    case credential(scope, endpoint["credential_ref_id"]) do
      {:ok, credential} -> {:ok, Map.put(config, :credential, credential)}
      :error -> {:error, unattempted(:credentials, "credential_unavailable")}
    end
  end

  defp field(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp credential(_scope, nil), do: {:ok, nil}

  defp credential(scope, ref_id) do
    case Settings.runtime().credential(scope, ref_id) do
      %Relay.Redacted{} = credential -> {:ok, credential}
      nil -> :error
    end
  end

  # WH-10
  defp settle(%{scope: scope} = run, attempt, now) do
    sealed = sealed(scope, attempt.answer)
    plan = plan(run, attempt.outcome, now)

    work = fn _status -> settled(run, attempt, sealed, plan, now) end

    case EngineStore.in_scope(scope, work) do
      {:ok, state} ->
        measure(run, attempt, plan)
        state

      {:error, _reason} ->
        :unsettled
    end
  end

  defp sealed(scope, %{body: body}) when is_binary(body) and body != "" do
    case Settings.sealer().seal(scope, @response_field, Relay.Redacted.wrap(body)) do
      {:ok, sealed} -> sealed
      {:error, _error} -> nil
    end
  end

  defp sealed(_scope, _answer), do: nil

  defp settled(run, attempt, sealed, plan, now) do
    %{delivery: %{message: message}, token: token} = run
    row = attempt_row(run, attempt, plan)
    digest = attempt.sent.body_digest

    case EngineStore.settle(message["id"], token, row, digest, sealed, plan.message, now) do
      {:settled, attempt_no} ->
        followed(run, attempt.outcome, plan, attempt_no, now)
        plan.state

      {_lost, _attempt_no} ->
        :lock_lost
    end
  end

  defp attempt_row(%{delivery: %{message: message}} = run, attempt, plan) do
    address = Map.get(attempt.answer, :address)
    ip? = is_binary(address) and match?({:ok, _ip}, :inet.parse_address(to_charlist(address)))

    %{
      "trigger_kind" => trigger(run, message),
      "started_at" => attempt.started_at,
      "duration_ms" => attempt.duration_ms,
      "result" => plan.result,
      "failure_code" => plan.code,
      "response_status" => attempt.outcome.status,
      "retry_after_seconds" => seconds(attempt.outcome.retry_after_ms),
      "webhook_timestamp" => attempt.sent.timestamp,
      "signature" => attempt.sent.signature,
      "destination_ip" => if(ip?, do: address),
      "destination_ref" => if(not ip? and is_binary(address) and address != "", do: address),
      "response_truncated" => Map.get(attempt.answer, :truncated, false)
    }
  end

  defp seconds(nil), do: nil
  defp seconds(ms), do: div(ms + 999, 1000)

  defp trigger(%{manual?: true}, _message), do: "manual"
  defp trigger(_run, %{"origin" => "test"}), do: "test"
  defp trigger(_run, %{"schedule_no" => no}) when no > 1, do: "recovery"
  defp trigger(_run, _message), do: "schedule"

  # WH-23
  # WH-25
  # WH-27
  # WH-32
  defp plan(%{manual?: true, delivery: %{message: message}}, %Outcome{} = outcome, _now) do
    case outcome.result do
      :delivered ->
        moved("delivered", nil, message["attempt_count"], message, "succeeded")

      _failed ->
        %{message: nil, state: :unchanged, result: result(outcome), code: Health.code(outcome)}
    end
  end

  defp plan(%{delivery: %{message: message}}, %Outcome{result: :delivered}, _now),
    do: moved("delivered", nil, message["attempt_count"] + 1, message, "succeeded")

  defp plan(%{delivery: delivery}, %Outcome{result: :retry} = outcome, now) do
    message = delivery.message
    progress = %{attempts: message["attempt_count"], deferrals: message["retry_after_count"]}
    deferrals = Settings.deferrals()

    opts = [
      jitter_bp: Settings.jitter_bp(),
      max_deferrals: deferrals.max,
      retry_after_ms: outcome.retry_after_ms,
      max_retry_after_ms: deferrals.max_ms
    ]

    code = Health.code(outcome)

    case RetrySchedule.after_failure(schedule(delivery), progress, message["id"], now, opts) do
      {:retry, at, progress, kind} -> retried(message, at, progress, kind, code, now)
      {:exhausted, progress} -> exhausted(message, progress, code)
    end
  end

  defp plan(%{delivery: %{message: message}}, %Outcome{} = outcome, _now) do
    state = Atom.to_string(outcome.result)
    count = message["attempt_count"] + 1
    moved(state, Health.code(outcome), count, message, result(outcome))
  end

  defp schedule(%{message: %{"origin" => "test"}}), do: [0]
  defp schedule(%{endpoint: endpoint}), do: Settings.schedule(endpoint)

  defp retried(message, at, progress, kind, code, now) do
    window = extended(message["window_ends_at"], kind, DateTime.diff(at, now, :second))

    %{
      message: %{
        "state" => "scheduled",
        "reason" => code,
        "attempt_count" => progress.attempts,
        "retry_after_count" => progress.deferrals,
        "next_attempt_at" => at,
        "window_ends_at" => window
      },
      state: :scheduled,
      next_at: at,
      result: if(kind == :retry_after, do: "deferred", else: "failed_retryable"),
      code: code
    }
  end

  defp extended(%DateTime{} = window, :retry_after, seconds),
    do: DateTime.add(window, seconds, :second)

  defp extended(_window, _kind, _seconds), do: nil

  defp exhausted(message, progress, code) do
    attempts = progress.attempts
    plan = moved("exhausted", "attempts_exhausted", attempts, message, "failed_retryable")
    %{plan | code: code}
  end

  defp moved(state, reason, attempts, message, result) do
    %{
      message: %{
        "state" => state,
        "reason" => reason,
        "attempt_count" => attempts,
        "retry_after_count" => message["retry_after_count"]
      },
      state: String.to_existing_atom(state),
      result: result,
      code: reason
    }
  end

  defp result(%Outcome{reason: :aborted_by_consumer}), do: "aborted"
  defp result(%Outcome{result: :retry}), do: "failed_retryable"
  defp result(%Outcome{}), do: "failed_permanent"

  defp followed(%{delivery: delivery} = run, outcome, plan, attempt_no, now) do
    %{message: message, endpoint: endpoint, event: event} = delivery

    if plan.state == :scheduled, do: :ok = Fanout.attempt_job(message["id"], plan.next_at)
    if run.manual? and plan.state == :delivered, do: Settings.runtime().cancel(message["id"])

    if message["origin"] != "test" do
      if plan.state == :exhausted, do: exhausted_event(endpoint["id"], event, message, attempt_no)
      health(endpoint, outcome, run.decision, now)
    end

    :ok
  end

  # WH-34
  defp exhausted_event(endpoint_id, event, message, attempt_no) do
    payload = %{
      "endpoint_id" => external(endpoint_id),
      "event_id" => webhook_id(event),
      "attempts" => attempt_no
    }

    :appended = EngineStore.outbox_append("webhook.attempt_exhausted", endpoint_id, payload)
    notice("attempt_exhausted", endpoint_id, message["id"])
  end

  # WH-35
  # WH-36
  defp health(%{"id" => id} = endpoint, outcome, decision, now) do
    row = EngineStore.health_lock(id)
    params = Settings.health()
    {row, effects} = Health.record(row, outcome, decision, endpoint["auto_disable"], now, params)
    :saved = EngineStore.health_save(id, Health.columns(row), now)
    Enum.each(effects, &effect(&1, id, row, now))
  end

  # WH-35
  # WH-36
  # WH-39
  @doc "Applies what an endpoint's health asks for inside the caller's scoped transaction: the release of held messages when the breaker opened or closed, the warning, or the automatic disable with its event."
  @spec effect(Health.effect(), Relay.Id.t(), Health.row(), DateTime.t()) :: :ok
  def effect(:breaker_opened, id, row, _now) do
    :ok = Fanout.release_job(id, "breaker_open", row["breaker_retry_at"])
  end

  def effect(:breaker_closed, id, _row, now) do
    :ok = Fanout.release_job(id, "breaker_open", now)
  end

  def effect(:warn, id, _row, _now), do: notice("endpoint_unresponsive", id, id)
  def effect(:disable_gone, id, _row, now), do: disable(id, "gone", now)
  def effect(:disable_failing, id, _row, now), do: disable(id, "failing", now)

  # WH-23
  # WH-36
  # WH-34
  defp disable(id, reason, now) do
    scope = EngineStore.current_scope()
    {:ok, actor} = Relay.Actor.new(:system, "relay-webhooks", "relay-webhooks")
    digest = digest(scope, id, reason)

    case EngineStore.endpoint_set_state(id, "disabled", reason, digest, actor, now) do
      {:changed, _version} ->
        payload = %{"endpoint_id" => external(id), "reason" => reason}
        :appended = EngineStore.outbox_append("webhook_endpoint.disabled", id, payload)
        notice("endpoint_disabled", id, id)

      {_unchanged, _version} ->
        :ok
    end
  end

  @doc "The audit record digest of an engine action on an endpoint."
  @spec digest(Scope.t(), Relay.Id.t(), String.t()) :: <<_::256>>
  def digest(%Scope{} = scope, endpoint_id, action) do
    fields = [
      "webhook_endpoint." <> action,
      {:bytes, scope.tenant_id},
      Atom.to_string(scope.environment),
      Relay.Id.to_string(endpoint_id)
    ]

    :crypto.hash(:sha256, Relay.Canonical.encode!(fields))
  end

  # WH-34
  # WH-56
  @doc "Queues the operations e-mail of `kind` about an endpoint inside the caller's scoped transaction; `ref_id` is the message or endpoint it is about."
  @spec notice(String.t(), Relay.Id.t(), Relay.Id.t()) :: :ok
  def notice(kind, endpoint_id, ref_id) do
    args =
      EngineStore.current_scope()
      |> Scope.to_job_args()
      |> Map.merge(%{"kind" => kind, "endpoint_id" => Relay.Id.to_string(endpoint_id)})

    _ = Settings.runtime().enqueue(%{worker: NoticeWorker, args: args, ref_id: ref_id})
    :ok
  end

  defp external(endpoint_id), do: Relay.ExternalId.encode("whe", endpoint_id)

  defp measure(%{delivery: %{message: message}} = run, attempt, plan) do
    :telemetry.execute(
      [:relay, :webhooks, :attempt],
      %{count: 1, duration_ms: attempt.duration_ms},
      %{
        result: plan.result,
        trigger: trigger(run, message),
        first: message["total_attempt_count"] == 0
      }
    )
  end
end
