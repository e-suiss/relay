defmodule Relay.Api.Previews do
  @moduledoc """
  The synchronous previews of the server API (API-60, TP-38, TP-39, TP-47, TP-53): a template's draft, live or numbered version rendered per channel, and a workflow's steps with, for each, whether it would send, the `rule_id` of a template rule that stops it (`template.not_published`, `template.archived`, `template.variant_missing`, `template.locale_missing`) and the render. Nothing is sent and no record is opened.

  Sample data is the request's `data`, or one of the sample sources in priority order: the schema's first example, the newest of the last 20 accepted events of the workflow within 7 days masked at preview time and never stored (events whose content is not kept are left out), and the `max` boundary sample. A source that has no data is `preview_sample_unavailable`.

  A render carries the channel's rendered fields, the measures, and for SMS the planned encoding with its counterpart on a provider not verified for the Turkish single shift (every provider until the provider catalogue, TP-53), the segments and the characters; a missing variable is `failure_reason: missing_variable` with a `missing_variable` warning. Rendered HTML is data in a JSON response that forbids every active content (`Content-Security-Policy: sandbox`); only the console's sandboxed preview origin displays it (TP-39).
  """

  alias Relay.Api.Gate
  alias Relay.Api.Templates
  alias Relay.TemplateStore

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  @headers [
    {"content-security-policy", "default-src 'none'; frame-ancestors 'none'; sandbox"},
    {"x-content-type-options", "nosniff"}
  ]
  @too_large [:push_payload_size, :push_characters, :email_html_size]
  @rules [
    "template.not_published",
    "template.archived",
    "template.variant_missing",
    "template.locale_missing"
  ]

  @doc "The headers of a preview response: JSON data that no browser renders as an active document."
  @spec headers() :: [{String.t(), String.t()}]
  def headers, do: @headers

  # API-60
  # TP-38
  @doc "Previews a template version per channel with sample or given data."
  @spec template(Relay.Scope.t(), Templates.at(), map()) :: answer()
  def template(scope, at, body) do
    with {:ok, read} <- read_template(scope, at, body),
         {:ok, locale} <- locale(body["locale"]),
         {:ok, sample, data} <- sample(scope, body, read.schema, body["workflow"]) do
      channels = body["channels"] || channel_keys(read.definition)

      preview = %{
        "object" => "template_preview",
        "template_key" => at.key,
        "version" => read.label,
        "sample" => sample,
        "renders" => Enum.map(channels, &render(read, &1, locale, data))
      }

      {:ok, {200, @headers, preview}}
    end
  end

  defp read_template(scope, at, body) do
    read =
      TemplateStore.in_scope(scope, fn _status ->
        with {:ok, t} <- Templates.found(at),
             {:ok, label, v} <- pick(t, body["version"]),
             {:ok, schema} <- schema(body["workflow"]) do
          {:ok, context(at, t, v, label, schema)}
        end
      end)

    unwrap(read)
  end

  defp context(at, t, v, label, schema) do
    %{
      label: label,
      definition: Templates.definition(v),
      message_class: t["message_class"],
      schema: schema,
      facts: TemplateStore.tenant_facts(),
      brand: brand(at.subtenant_id, v["id"])
    }
  end

  defp pick(t, nil) do
    case TemplateStore.template_draft(t["id"]) do
      nil -> pick(t, "live")
      draft -> {:ok, "draft", draft}
    end
  end

  defp pick(t, "draft") do
    case TemplateStore.template_draft(t["id"]) do
      nil -> {:error, Templates.version_not_found()}
      draft -> {:ok, "draft", draft}
    end
  end

  defp pick(%{"live_version_no" => nil}, "live"), do: {:error, Templates.version_not_found()}
  defp pick(t, "live"), do: pick(t, t["live_version_no"], "live")
  defp pick(t, number) when is_integer(number), do: pick(t, number, number)

  defp pick(t, number, label) do
    case TemplateStore.template_version(t["id"], number) do
      nil -> {:error, Templates.version_not_found()}
      v -> {:ok, label, v}
    end
  end

  defp schema(workflow_key) do
    case Relay.Workflow.resolve(workflow_key) do
      {:ok, row} ->
        {:ok, row["event_schema"] || %{}}

      :not_published ->
        draft = Relay.Workflow.view(workflow_key)["draft"]
        {:ok, (draft && draft["definition"]["event_schema"]) || %{}}

      :not_found ->
        {:error, workflow_not_found()}
    end
  end

  defp brand(subtenant_id, version_id) do
    for {field, %{value: value}} <- TemplateStore.brand_resolve(subtenant_id, version_id),
        value != nil,
        into: %{},
        do: {field, value}
  end

  defp channel_keys(definition),
    do: definition |> Map.get("cells", %{}) |> Map.keys() |> Enum.sort()

  # TP-56
  defp locale(nil), do: {:ok, nil}

  defp locale(locale) do
    if Relay.Templates.locale_supported?(locale),
      do: {:ok, locale},
      else: {:error, Relay.Error.new(:locale_not_supported, "the locale is not supported")}
  end

  # TP-38
  # TP-47
  defp sample(_scope, %{"data" => data}, _schema, _workflow) when is_map(data),
    do: {:ok, "data", data}

  defp sample(scope, body, schema, workflow) do
    case body["sample"] do
      nil -> first_sample(scope, schema, workflow)
      source -> source |> source(scope, schema, workflow) |> available(source)
    end
  end

  defp first_sample(scope, schema, workflow) do
    Enum.find_value(["schema_examples", "masked_recent"], fn source ->
      case source(source, scope, schema, workflow) do
        nil -> nil
        data -> {:ok, source, data}
      end
    end) || {:ok, "boundary", source("boundary", scope, schema, workflow)}
  end

  defp available(nil, _source),
    do:
      {:error,
       Relay.Error.new(
         :preview_sample_unavailable,
         "the sample source has no data; choose another sample or send data"
       )}

  defp available(data, source), do: {:ok, source, data}

  defp source("schema_examples", _scope, schema, _workflow) do
    case Relay.Templates.examples(schema) do
      [{_name, data} | _rest] -> data
      [] -> nil
    end
  end

  defp source("masked_recent", scope, schema, workflow) do
    window = Relay.Templates.real_event_window()
    since = DateTime.add(Relay.Clock.utc_now(), -window.days * 86_400, :second)
    read = fn _status -> TemplateStore.recent_events(workflow, since, window.count) end

    case TemplateStore.in_scope(scope, read) do
      {:ok, rows} -> Enum.find_value(rows, &masked(scope, &1, schema))
      {:error, _reason} -> nil
    end
  end

  defp source("boundary", _scope, schema, _workflow) do
    schema
    |> Relay.Templates.boundary()
    |> List.keyfind("max", 0)
    |> elem(1)
  end

  # TP-47
  defp masked(scope, row, schema) do
    field = %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: nil,
      retention_class: :notification_content,
      table: "event_payloads",
      column: "data_ct",
      key_id: row["key_id"]
    }

    with {:ok, plain} <- Relay.Tenancy.decrypt_field(field, row["data_ct"]),
         {:ok, %{} = data} <- Jason.decode(Relay.Redacted.expose(plain)) do
      Relay.Templates.mask(data, schema)
    else
      _unreadable -> nil
    end
  end

  # TP-25
  # TP-26
  defp render(read, key, locale, data) do
    by_locale = get_in(read.definition, ["cells", key]) || %{}
    requested = locale || read.definition["default_locale"]

    if by_locale == %{} or Relay.Templates.channel(key) == nil,
      do: blank(key, requested, "variant_missing", "the template has no variant for the channel"),
      else: resolve(read, key, by_locale, requested, data)
  end

  defp resolve(read, key, by_locale, requested, data) do
    candidates = %{profile: requested, tenant_default: read.facts.default_locale}

    case Relay.Templates.resolve_locale(candidates, Map.keys(by_locale)) do
      {:ok, resolution} ->
        render_cell(read, key, by_locale[resolution.locale], resolution, data)

      {:error, :locale_missing} ->
        blank(key, requested, "locale_missing", "no cell matches the locale chain")
    end
  end

  defp blank(key, locale, code, message) do
    %{
      "channel" => key,
      "locale" => locale,
      "content" => nil,
      "failure_reason" => nil,
      "warnings" => [%{"code" => code, "message" => message}],
      "sms" => nil
    }
  end

  # TP-8
  defp render_cell(read, key, cell, resolution, data) do
    channel = Relay.Templates.channel(key)
    base = %{"channel" => key, "locale" => resolution.locale}
    base = Map.put(base, "locale_fallback", resolution.template_locale_missing)

    case compiled(channel, cell) do
      {:ok, html} ->
        channel
        |> Relay.Templates.render_cell(cell, options(read, resolution.locale, data, html))
        |> answer(base)

      {:error, error} ->
        warning = %{"code" => "mjml_compile", "message" => error.message}
        Map.merge(base, failed("schema_violation", [warning]))
    end
  end

  defp compiled(:email, %{"html_kind" => "raw_html"}), do: {:ok, nil}
  defp compiled(:email, cell), do: Relay.Templates.compile_mjml(cell["html"] || "")
  defp compiled(_channel, _cell), do: {:ok, nil}

  defp options(read, locale, data, html) do
    definition = read.definition

    [
      allow_raw: definition["allow_raw"] == true,
      html: html,
      locale: locale,
      time_zone: read.facts.default_timezone,
      data: partials(data, definition["partials"]),
      brand: read.brand,
      helpers: helpers(read.brand),
      variables: Relay.Templates.criticality(read.schema),
      sensitivity: Relay.Templates.sensitivity(definition["sensitivity"]),
      sms_policy: Relay.Templates.sms_policy(definition["sms_encoding"]),
      message_class: read.message_class
    ]
  end

  # TP-61
  defp partials(data, [_ | _] = keys), do: Map.put(data, "partial", Map.new(keys, &{&1, ""}))
  defp partials(data, _none), do: data

  # TP-55
  defp helpers(brand) do
    footer =
      ["legal_name", "mersis", "contact", "postal_address"]
      |> Enum.map(&brand[&1])
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" · ")

    %{"legal_footer" => footer, "unsubscribe_url" => "https://unsubscribe.invalid/preview"}
  end

  defp answer({:ok, result}, base) do
    reason = if result.content == nil, do: failure(result.findings)

    Map.merge(base, %{
      "content" => result.content,
      "failure_reason" => reason,
      "warnings" => Enum.map(result.findings, &warning/1),
      "measures" => Map.new(result.measures, fn {key, value} -> {Atom.to_string(key), value} end),
      "sms" => sms(result.sms)
    })
  end

  defp answer({:error, :missing_variable, variable}, base) do
    warning = %{
      "code" => "missing_variable",
      "variable" => variable,
      "message" => "the required variable is missing from the data"
    }

    Map.merge(base, failed("missing_variable", [warning]))
  end

  defp answer({:error, reason, _variable}, base) do
    code = Atom.to_string(reason)
    Map.merge(base, failed(code, [%{"code" => code, "message" => "the render failed"}]))
  end

  defp answer({:parse_error, errors}, base) do
    warnings =
      for {_pointer, found} <- errors, finding <- found do
        %{"code" => "parse", "message" => String.slice(finding.detail, 0, 1000)}
      end

    Map.merge(base, failed("schema_violation", warnings))
  end

  defp failed(reason, warnings),
    do: %{"content" => nil, "failure_reason" => reason, "warnings" => warnings, "sms" => nil}

  defp failure(findings) do
    if Enum.any?(findings, &(&1.check in @too_large)),
      do: "output_too_large",
      else: "schema_violation"
  end

  defp warning(finding) do
    view = Gate.view(finding)
    %{"code" => view["check"], "message" => view["message"]}
  end

  # TP-53
  defp sms(nil), do: nil

  defp sms(sms) do
    %{
      "encoding" => sms.encoding,
      "encoding_unverified_provider" => sms.encoding_unverified_provider,
      "segments" => sms.segments,
      "characters" => sms.characters
    }
  end

  # API-60
  @doc "Previews a workflow version step by step with sample or given data, for a given subscriber or a recipient with no preferences."
  @spec workflow(Relay.Scope.t(), String.t(), map(), Relay.Id.t() | nil) :: answer()
  def workflow(scope, key, body, subtenant_id) do
    with {:ok, wf} <- read_workflow(scope, key, body["version"]),
         {:ok, locale} <- locale(body["locale"]),
         {:ok, recipient_locale} <- recipient(scope, body["to"]),
         {:ok, sample, data} <- sample(scope, body, wf.schema, key),
         {:ok, steps} <- steps(scope, wf, subtenant_id) do
      locale = locale || recipient_locale

      preview = %{
        "object" => "workflow_preview",
        "workflow_key" => key,
        "version" => wf.label,
        "sample" => sample,
        "steps" => Enum.map(steps, &step(&1, wf.schema, locale, data))
      }

      {:ok, {200, @headers, preview}}
    end
  end

  defp read_workflow(scope, key, number) when is_integer(number) do
    case Relay.Workflow.get_version(scope, key, number) do
      {:ok, %{"definition" => definition}} -> {:ok, workflow_view(definition, number)}
      {:ok, :workflow_not_found} -> {:error, workflow_not_found()}
      {:ok, :version_not_found} -> {:error, workflow_version_not_found()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp read_workflow(scope, key, label) do
    scope
    |> TemplateStore.in_scope(fn _status -> workflow_definition(key, label) end)
    |> unwrap()
  end

  defp workflow_definition(key, label) do
    case {Relay.Workflow.resolve(key), label} do
      {:not_found, _label} -> {:error, workflow_not_found()}
      {{:ok, row}, label} when label in [nil, "live"] -> {:ok, live_workflow(row)}
      {:not_published, "live"} -> {:error, workflow_version_not_found()}
      {_resolved, _label} -> draft_workflow(key)
    end
  end

  defp live_workflow(row), do: workflow_view(row["definition"], "live")

  defp draft_workflow(key) do
    case Relay.Workflow.view(key) do
      %{"draft" => %{"definition" => definition}} -> {:ok, workflow_view(definition, "draft")}
      _none -> {:error, workflow_version_not_found()}
    end
  end

  defp workflow_view(definition, label),
    do: %{definition: definition, schema: definition["event_schema"] || %{}, label: label}

  defp recipient(_scope, nil), do: {:ok, nil}

  defp recipient(scope, external_id) do
    case Relay.Subscribers.fetch(scope, external_id) do
      {:ok, %{} = subscriber} -> {:ok, subscriber["locale"]}
      {:ok, nil} -> {:error, Relay.Error.new(:recipient_not_found, "no subscriber has this id")}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # TP-11
  # TP-51
  defp steps(scope, wf, subtenant_id) do
    steps = Relay.Workflow.steps(wf.definition)
    keys = steps |> Enum.map(& &1.template) |> Enum.uniq()

    read =
      TemplateStore.in_scope(scope, fn _status ->
        facts = TemplateStore.tenant_facts()
        live = Map.new(TemplateStore.template_live(keys, subtenant_id), &{&1["key"], &1})

        for step <- steps do
          row = Map.get(live, step.template, %{})
          {step, row, live_read(row, subtenant_id, facts)}
        end
      end)

    case read do
      {:ok, rows} -> {:ok, rows}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp live_read(%{"template_version_id" => nil}, _subtenant_id, _facts), do: nil
  defp live_read(row, _subtenant_id, _facts) when row == %{}, do: nil

  defp live_read(row, subtenant_id, facts) do
    v = TemplateStore.template_version(row["template_id"], row["version_no"])

    %{
      label: "live",
      definition: Templates.definition(v),
      message_class: row["message_class"],
      facts: facts,
      brand: brand(subtenant_id, v["id"])
    }
  end

  defp step({step, row, read}, schema, locale, data) do
    base = %{"step" => step.key, "channel" => step.channel, "template" => step.template}

    case {row["rule_id"], read} do
      {rule, _read} when rule in @rules -> stopped(base, rule)
      {_rule, nil} -> stopped(base, "template.not_published")
      {_rule, read} -> sent(base, Map.put(read, :schema, schema), step.channel, locale, data)
    end
  end

  defp sent(base, read, channel, locale, data) do
    render = render(read, channel, locale, data)

    case render["warnings"] do
      [%{"code" => "variant_missing"}] -> stopped(base, "template.variant_missing")
      [%{"code" => "locale_missing"}] -> stopped(base, "template.locale_missing")
      _warnings -> Map.merge(base, decision(render))
    end
  end

  defp decision(%{"failure_reason" => nil} = render),
    do: %{"would_send" => true, "reason" => nil, "rule_id" => nil, "render" => render}

  defp decision(render) do
    decision = %{"would_send" => false, "reason" => "render_failed", "rule_id" => nil}
    rendered(decision, render)
  end

  defp rendered(decision, render), do: Map.put(decision, "render", render)

  defp stopped(base, rule) do
    decision = %{"would_send" => false, "reason" => "template", "rule_id" => rule}
    base |> Map.merge(decision) |> rendered(nil)
  end

  defp unwrap({:ok, {:ok, value}}), do: {:ok, value}
  defp unwrap({:ok, {:error, error}}), do: {:error, error}
  defp unwrap({:error, _reason}), do: {:error, unavailable()}

  defp workflow_not_found, do: Relay.Error.new(:workflow_not_found, "no workflow has this key")

  defp workflow_version_not_found,
    do: Relay.Error.new(:workflow_version_not_found, "the workflow has no such version")

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again")
end
