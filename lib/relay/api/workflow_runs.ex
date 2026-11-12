defmodule Relay.Api.WorkflowRuns do
  @moduledoc """
  The send path's side of workflow runs (WF-59 (5), WF-43, WF-7). At acceptance `plan/3` freezes what a later step of the run needs to open its delivery the way the accepting request would have: the request's send fields, its prepared channel steps with their subtype rules, the providers they are narrowed to, the template versions resolved at acceptance (WF-7: a later step sends the versions frozen when the notification was created, never a newer one), the tenant's default locale and time zone, the event time and the test device of a test send. The plan holds keys, codes and identifiers only, never event data or a personal value. `context/2` gives the step context of the accepting run.

  `resume/2` is the resumer of `Relay.Workflow` (`config :relay, Relay.Workflow, resumer: Relay.Api.WorkflowRuns`). Outside any transaction it reads what changes between deliveries (the category's policy, the tenant's send mode and provider settings, the frequency readings) and decrypts the event data under the tenant data key; it returns a function that, inside the run's transaction, reads the recipient and gives the step context and the opener, which opens a channel step's delivery through `Relay.Api.Events.open_step/6`. Gates are evaluated again for every delivery (WF-7).
  """

  alias Relay.Api.Events
  alias Relay.Policy.Live

  @classes Map.new(
             ~w(security transactional operational social marketing system action_required)a,
             &{Atom.to_string(&1), &1}
           )
  @channels Map.new(
              ~w(push web_push email sms voice whatsapp slack teams telegram discord in_app
                 webhook)a,
              &{Atom.to_string(&1), &1}
            )
  @attributes ~w(locale timezone legal_type)
  @domestic "channels.domestic_only"

  # WF-7
  # WF-59 (5)
  @doc "The plan of a notification's run: what its later steps need to open their deliveries, as JSON without personal data."
  @spec plan(Events.prepared(), map(), boolean()) :: map()
  def plan(p, row, mismatch?) do
    %{
      "category" => p.category,
      "message_class" => p.message_class,
      "event_time" => DateTime.to_iso8601(p.now),
      "mismatch" => mismatch?,
      "is_test" => Map.get(p, :is_test, false),
      "test_device" => test_device(p, row),
      "traceparent" => p.traceparent,
      "request" => %{
        "send_mode" => p.request.send_mode,
        "priority" => p.request.priority,
        "security_subtype" => p.request.security_subtype,
        "sender_type" => p.request.sender_type,
        "on_expire" => p.request.on_expire,
        "timing_precision" => p.request.timing_precision
      },
      "steps" => Enum.map(p.request.steps, &step/1),
      "routes" => Map.get(p, :routes, %{}),
      "providers" => p.providers,
      "templates" => templates(p.templates)
    }
  end

  defp test_device(%{test_devices: devices}, %{"id" => id}) do
    case Map.get(devices, id) do
      nil -> nil
      device -> hex(device)
    end
  end

  defp test_device(_p, _row), do: nil

  defp step(step) do
    skip =
      case step.skip do
        {reason, rule} -> [reason, rule]
        nil -> nil
      end

    %{
      "key" => step.key,
      "channel" => step.channel,
      "template" => step.template,
      "digest_template" => Map.get(step, :digest_template),
      "skip" => skip
    }
  end

  defp templates(templates) do
    entries =
      for {key, entry} <- templates, is_binary(key), into: %{} do
        {key,
         %{
           "key" => entry.key,
           "rule_id" => entry.rule_id,
           "template_version_id" => hex(entry.template_version_id),
           "version_no" => entry.version_no,
           "layout_key" => entry.layout_key,
           "layout_version_id" => hex(entry.layout_version_id),
           "partial_version_ids" => Enum.map(entry.partial_version_ids, &hex/1),
           "locales" => entry.locales
         }}
      end

    %{
      "default_locale" => templates.default_locale,
      "default_timezone" => Map.get(templates, :default_timezone),
      "entries" => entries
    }
  end

  defp hex(nil), do: nil
  defp hex(binary) when is_binary(binary), do: Base.encode16(binary, case: :lower)

  defp unhex(nil), do: nil
  defp unhex(text), do: Base.decode16!(text, case: :lower)

  # WF-45
  # WF-60
  @doc "The step context of a run at acceptance, with the recipient's declared attributes read before the transaction (`attributes/3`)."
  @spec context(Events.prepared(), map(), map()) :: map()
  def context(p, row, attributes) do
    definition = p.workflow["definition"]

    %{
      data: p.request.data,
      recipient: declared(row, attributes, definition),
      time_zone: zone(row, Map.get(p.templates, :default_timezone)),
      event_time: p.now,
      run_started_at: p.request.send_at || p.now,
      message_class: p.message_class,
      routes: Map.get(p, :routes, %{}),
      facts: facts()
    }
  end

  # WF-13
  # WF-16
  defp facts, do: fn _step -> %{} end

  # WF-10
  # WF-59
  @doc "Reads the recipients' attributes a definition declares, outside any transaction: the attributes the request writes, else the subscriber's stored attributes, decrypted under its profile key. A definition that declares none reads nothing."
  @spec attributes(Relay.Scope.t(), map(), [map()]) :: {:ok, [map()]}
  def attributes(scope, definition, recipients) do
    if (definition["recipient_attributes"] || %{}) == %{},
      do: {:ok, recipients},
      else: {:ok, Enum.map(recipients, &Map.put(&1, :attributes, stored(scope, &1)))}
  end

  defp stored(_scope, %{fields: %{"attributes" => %{} = attributes}}), do: attributes

  defp stored(scope, %{plan: %{existing: %{"id" => id}}}), do: stored(scope, id)

  defp stored(scope, id) when is_binary(id) do
    case Relay.Ingest.in_event_scope(scope, fn _status ->
           Relay.Subscribers.personal_record(id)
         end) do
      {:ok, record} ->
        Relay.Subscribers.open_personal(scope, record, ["attributes"])["attributes"] || %{}

      {:error, _reason} ->
        %{}
    end
  end

  defp stored(_scope, _recipient), do: %{}

  defp declared(row, attributes, definition) do
    for {name, type} <- definition["recipient_attributes"] || %{}, into: %{} do
      value = Map.get(attributes || %{}, name) || (name in @attributes && row && row[name]) || nil
      {name, typed(type, value)}
    end
  end

  defp typed("timestamp", text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      {:error, _reason} -> nil
    end
  end

  defp typed("string", value) when is_binary(value), do: value
  defp typed("number", value) when is_number(value), do: value
  defp typed("boolean", value) when is_boolean(value), do: value
  defp typed(_type, _value), do: nil

  defp zone(row, tenant_zone) do
    Enum.find_value([row && row["timezone"], tenant_zone], fn name ->
      case Relay.TimeZone.new(name) do
        {:ok, zone} -> zone
        {:error, _error} -> nil
      end
    end)
  end

  # WF-43
  # WF-7
  @doc "Prepares the waking of a run outside any transaction; the returned function, called inside the run's transaction, gives the step context and the opener."
  @spec resume(Relay.Scope.t(), map()) ::
          {:ok, (-> {:ok, map(), (map(), String.t(), String.t() -> term())})}
          | {:error, term()}
  def resume(scope, run) do
    plan = run["plan"]
    subtenant = if run["subtenant_id"], do: {:ok, run["subtenant_id"]}, else: nil

    with {:ok, data} <- data(scope, run["event_id"]),
         {:ok, policy} <- category(scope, plan, run["subtenant_id"]),
         {:ok, settings, installation} <- settings(scope, run["workflow_key"], plan) do
      p = %{
        scope: scope,
        workflow: %{
          "key" => run["workflow_key"],
          "version_no" => run["version_no"],
          "workflow_id" => run["workflow_id"],
          "version_id" => run["workflow_version_id"],
          "definition" => run["definition"]
        },
        category: plan["category"],
        policy: policy,
        message_class: plan["message_class"],
        now: Relay.Clock.business_now(scope),
        expires_at: run["expires_at"],
        frequency: frequency(scope, policy, run["recipient_id"], plan),
        request: request(plan),
        providers: plan["providers"] || %{},
        templates: decode_templates(plan["templates"]),
        settings: settings,
        installation_mode: installation,
        subtenant: subtenant,
        traceparent: plan["traceparent"],
        is_test: plan["is_test"] == true
      }

      attributes = if run_declares?(run), do: stored(scope, run["recipient_id"]), else: %{}
      {:ok, fn -> bind(with_device(p, run, plan), run, data, attributes) end}
    end
  end

  defp with_device(p, run, %{"test_device" => device}) when is_binary(device),
    do: Map.put(p, :test_devices, %{run["recipient_id"] => unhex(device)})

  defp with_device(p, _run, _plan), do: p

  defp run_declares?(run), do: (run["definition"]["recipient_attributes"] || %{}) != %{}

  defp bind(p, run, data, attributes) do
    recipient_id = run["recipient_id"]
    row = Events.device_locale(Relay.Subscribers.row(recipient_id), recipient_id)
    mismatch? = run["plan"]["mismatch"] == true
    notification_id = run["notification_id"]

    context = %{
      data: data,
      recipient: declared(row, attributes, run["definition"]),
      time_zone: zone(row, p.templates.default_timezone),
      event_time: event_time(run["plan"]["event_time"]),
      run_started_at: run["started_at"],
      message_class: p.message_class,
      routes: run["plan"]["routes"] || %{},
      facts: facts()
    }

    opener = fn step, channel, pointer ->
      Events.open_step(p, notification_id, row, mismatch?, step, {channel, pointer})
    end

    {:ok, context, opener}
  end

  defp event_time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      {:error, _reason} -> nil
    end
  end

  defp event_time(_text), do: nil

  defp request(plan) do
    request = plan["request"] || %{}

    %{
      send_mode: request["send_mode"],
      send_at: nil,
      priority: request["priority"],
      security_subtype: request["security_subtype"],
      sender_type: request["sender_type"],
      on_expire: request["on_expire"],
      timing_precision: request["timing_precision"],
      steps: Enum.map(plan["steps"] || [], &decode_step/1)
    }
  end

  defp decode_step(step) do
    skip =
      case step["skip"] do
        [reason, rule] -> {reason, rule}
        nil -> nil
      end

    %{
      key: step["key"],
      channel: step["channel"],
      template: step["template"],
      digest_template: step["digest_template"],
      skip: skip
    }
  end

  defp decode_templates(templates) do
    entries =
      Map.new(templates["entries"] || %{}, fn {key, entry} ->
        {key,
         %{
           key: entry["key"],
           rule_id: entry["rule_id"],
           template_version_id: unhex(entry["template_version_id"]),
           version_no: entry["version_no"],
           layout_key: entry["layout_key"],
           layout_version_id: unhex(entry["layout_version_id"]),
           partial_version_ids: Enum.map(entry["partial_version_ids"] || [], &unhex/1),
           locales: entry["locales"] || %{}
         }}
      end)

    Map.merge(entries, %{
      default_locale: templates["default_locale"],
      default_timezone: templates["default_timezone"]
    })
  end

  # PC-57 (3)
  defp category(scope, plan, subtenant_id) do
    class = Map.fetch!(@classes, plan["message_class"])

    case Live.category(scope, plan["category"] || plan["message_class"], class, subtenant_id) do
      {:ok, category} -> {:ok, category}
      {:error, _reason} -> {:error, :category_unavailable}
    end
  end

  # OP-51
  # C-89
  defp settings(scope, workflow_key, plan) do
    steps = plan["steps"] || []

    modes =
      Enum.flat_map(
        steps,
        &Relay.Ingest.send_mode_keys(workflow_key, plan["category"], &1["channel"])
      )

    providers = Enum.map(steps, &"overrides.#{&1["channel"]}.provider")
    keys = Enum.uniq([@domestic | modes ++ providers])

    with {:ok, settings} <-
           Relay.Ingest.in_event_scope(scope, fn _status -> Relay.Ingest.settings(keys) end),
         {:ok, installation} <- Relay.Ingest.installation_send_mode() do
      {:ok, settings, installation}
    end
  end

  # PC-58 (6)
  defp frequency(scope, policy, recipient_id, plan) do
    for %{"channel" => name} <- plan["steps"] || [],
        channel = Map.fetch!(@channels, name),
        into: %{} do
      readings = Live.frequency(scope, policy, policy.message_class, recipient_id, channel)
      {{recipient_id, channel}, readings}
    end
  end

  # WF-60
  defp data(scope, event_id) do
    case Relay.Ingest.in_event_scope(scope, fn _status -> Relay.Ingest.event_data(event_id) end) do
      {:ok, %{"erased_at" => %DateTime{}}} ->
        {:ok, %{}}

      {:ok, %{"data_ct" => ct, "key_id" => key_id}} when is_binary(ct) ->
        decrypt(scope, key_id, ct)

      {:ok, _none} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decrypt(scope, key_id, ct) do
    field = %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: nil,
      retention_class: :notification_content,
      table: "event_payloads",
      column: "data_ct",
      key_id: key_id
    }

    with {:ok, plain} <- Relay.Tenancy.decrypt_field(field, ct),
         {:ok, data} <- Jason.decode(Relay.Redacted.expose(plain)) do
      {:ok, data}
    else
      _unreadable -> {:error, :data_unavailable}
    end
  end
end
