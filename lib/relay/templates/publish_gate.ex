defmodule Relay.Templates.PublishGate do
  @moduledoc """
  The publication gate of templates, layouts and partials (TP-31, TP-32). It is pure apart from the MJML compiler, which the caller passes as a function and which is the only publication-time step that leaves the BEAM (TP-8); it reads nothing and writes nothing, and returns the findings with the variable usage index and the worst-case measures that the version records.

  Hard checks of a template: every locale × channel cell parses within the static limits (TP-6) in a supported locale (TP-56); variables match every event schema of the workflows that use the template, with no undeclared variable and the criticality rules (TP-13, TP-14, TP-16); the email variant has its plain text body; MJML compiles, MJML first and Liquid on the compiled HTML (TP-8), and declares every icon of `mj-social`, `mj-carousel` and `mj-accordion` (TP-58); a sensitivity class is chosen and a sensitive term match is confirmed (TP-21, TP-46); the push variant stays within 1024 characters and 4096 bytes in the worst case (TP-20); no promotion in a transactional or operational template (TP-12, TP-54); the legal footer of a commercial template (TP-33, TP-55); every ICU plural and select form of the cell locale (TP-59); no emoji in SMS template text (TP-19); a machine translated cell is approved (TP-30).

  Warnings: the variable sets of the locales of one channel differ; worst-case lengths over the channel limits (SMS segments and characters that force UCS-2, WhatsApp parameters, email size and subject); the accessibility and content lint (TP-34). The worst case renders the automatic boundary samples of the schemas (TP-38); SMS is measured on the `max` and `turkish` samples, since emoji in values are flagged at send time (TP-19).
  """

  alias Relay.Templates.CellRender
  alias Relay.Templates.Cldr
  alias Relay.Templates.Engine
  alias Relay.Templates.Filters
  alias Relay.Templates.Finding
  alias Relay.Templates.Lint.Accessibility
  alias Relay.Templates.Lint.LegalFooter
  alias Relay.Templates.Lint.Promotion
  alias Relay.Templates.Lint.Sensitive
  alias Relay.Templates.Locale
  alias Relay.Templates.Samples
  alias Relay.Templates.Sms.Content
  alias Relay.Templates.Variables
  alias Relay.Templates.Walk

  @type compile :: (String.t() -> {:ok, String.t()} | {:error, Relay.Error.t()})
  @type input :: %{
          required(:definition) => map(),
          required(:message_class) => String.t(),
          optional(:schemas) => [map()],
          optional(:brand) => map(),
          optional(:country) => String.t() | nil,
          optional(:sensitive_terms) => [map()],
          optional(:promotional_terms) => [map()],
          optional(:supported_locales) => [String.t()],
          optional(:compile) => compile() | nil
        }
  @type result :: %{
          findings: [Finding.t()],
          variables: %{String.t() => [String.t()]},
          measures: map(),
          compiled: %{String.t() => String.t()}
        }

  @empty_schema %{"type" => "object", "properties" => %{}}
  @helpers ["legal_footer", "unsubscribe_url"]
  @layout_helpers ["legal_footer", "unsubscribe_url", "content_for_layout"]
  @not_required ["brand", "recipient", "partial", "legal_footer", "unsubscribe_url"]
  @sms_segments 1
  @sms_samples ["max", "turkish"]
  @lint_sample "max"
  @worst_limits [timeout_ms: 1_000, max_heap_bytes: 256 * 1024 * 1024]
  @social ~r/<mj-social-element\b[^>]*>/i
  @carousel ~r/<mj-carousel(?![-\w])[^>]*>/i
  @accordion ~r/<mj-accordion(?![-\w])[^>]*>/i

  # TP-31
  # TP-32
  @doc "Runs the gate over a template definition; see the module documentation for the checks and `t:input/0` for the inputs."
  @spec template(input()) :: result()
  def template(input) do
    definition = input.definition
    cells = cells(definition)
    {compiled, mjml} = compile_cells(cells, Map.get(input, :compile))
    schemas = schemas(input)

    ctx = %{
      input: input,
      definition: definition,
      schemas: schemas,
      compiled: compiled,
      partials: partials(definition),
      optional: Enum.map(schemas, &Variables.criticality/1)
    }

    results = Enum.map(cells, &check_cell(&1, ctx))

    findings =
      definition_findings(definition, input) ++
        mjml ++
        Enum.flat_map(results, & &1.findings) ++
        sensitivity_findings(results, definition, input) ++
        legal_findings(results, input) ++ locale_set_findings(results)

    %{
      findings: Enum.uniq(findings),
      variables: usage(results),
      measures: measures(results),
      compiled: compiled
    }
  end

  defp partials(definition) do
    case definition["partials"] do
      keys when is_list(keys) -> keys
      _none -> []
    end
  end

  defp schemas(input) do
    case Map.get(input, :schemas, []) do
      [] -> [@empty_schema]
      schemas -> schemas
    end
  end

  # TP-9
  @doc "The cells of a definition as `{channel_key, channel, locale, cell}`, in a stable order."
  @spec cells(map()) :: [{String.t(), atom(), String.t(), map()}]
  def cells(definition) do
    for {key, by_locale} <- Enum.sort(Map.get(definition, "cells") || %{}),
        channel = CellRender.channel(key),
        is_map(by_locale),
        {locale, cell} <- Enum.sort(by_locale),
        is_map(cell),
        do: {key, channel, locale, cell}
  end

  defp definition_findings(definition, input) do
    supported = Map.get(input, :supported_locales, Cldr.supported_locales())
    locales = [definition["default_locale"] | Enum.map(cells(definition), &elem(&1, 2))]
    locale_findings(locales, supported) ++ translation_findings(definition)
  end

  defp locale_findings(locales, supported) do
    for locale <- Enum.uniq(locales), is_binary(locale), not supported?(locale, supported) do
      Finding.new(:locale_not_supported, :hard, locale: locale)
    end
  end

  # TP-56
  @doc "Whether a locale is valid BCP 47 and its language is one of `supported`."
  @spec supported?(String.t(), [String.t()]) :: boolean()
  def supported?(locale, supported) do
    language = locale |> String.split("-", parts: 2) |> hd() |> String.downcase()
    language in supported and Locale.supported?(locale)
  end

  # TP-30
  @doc "The cells whose machine translation no person approved, as hard findings."
  @spec translation_findings(map()) :: [Finding.t()]
  def translation_findings(definition) do
    for {_key, channel, locale, cell} <- cells(definition),
        cell["machine_translated"] == true,
        cell["translation_approved_by"] in [nil, ""] do
      Finding.new(:translation_unapproved, :hard, channel: channel, locale: locale)
    end
  end

  # TP-8
  # TP-58
  defp compile_cells(cells, compile) do
    Enum.reduce(cells, {%{}, []}, fn
      {_key, :email, locale, cell}, {compiled, findings} ->
        if mjml?(cell) do
          fields = [channel: :email, locale: locale]
          {html, found} = compile_one(cell["html"] || "", compile, fields)
          {put_compiled(compiled, locale, html), findings ++ found}
        else
          {compiled, findings}
        end

      _other, acc ->
        acc
    end)
  end

  defp put_compiled(compiled, _locale, nil), do: compiled
  defp put_compiled(compiled, locale, html), do: Map.put(compiled, locale, html)

  defp mjml?(cell), do: Map.get(cell, "html_kind", "mjml") == "mjml"

  defp compile_one(source, compile, fields) do
    fields = Keyword.put(fields, :pointer, Keyword.get(fields, :pointer, "/html"))
    assets = asset_findings(source, fields)

    case compile && compile.(source) do
      nil -> {nil, assets}
      {:ok, html} -> {html, assets}
      {:error, error} -> {nil, assets ++ [mjml_finding(error, fields)]}
    end
  end

  defp mjml_finding(%Relay.Error{code: code, details: details}, fields) do
    detail =
      details
      |> Map.take([:line, :column])
      |> Map.put(:code, Atom.to_string(code))

    Finding.new(:mjml_compile, :hard, Keyword.put(fields, :detail, detail))
  end

  # TP-58
  @doc "The `mj-social`, `mj-carousel` and `mj-accordion` elements of an MJML source that leave an icon or arrow image to the compiler's default, as hard findings; `fields` are the finding fields."
  @spec asset_findings(String.t(), keyword()) :: [Finding.t()]
  def asset_findings(source, fields \\ []) do
    [
      {@social, "mj-social-element", ["src"]},
      {@carousel, "mj-carousel", ["left-icon", "right-icon"]},
      {@accordion, "mj-accordion", ["icon-wrapped-url", "icon-unwrapped-url"]}
    ]
    |> Enum.flat_map(fn {pattern, element, attributes} ->
      pattern
      |> Regex.scan(source)
      |> Enum.count(fn [tag] -> Enum.any?(attributes, &(not attribute?(tag, &1))) end)
      |> asset_finding(element, attributes, fields)
    end)
  end

  defp attribute?(tag, name), do: Regex.match?(~r/\s#{name}\s*=\s*["']?[^"'\s>]/i, tag)

  defp asset_finding(0, _element, _attributes, _fields), do: []

  defp asset_finding(count, element, attributes, fields) do
    detail = %{element: element, count: count, attributes: attributes}
    [Finding.new(:mjml_default_asset, :hard, Keyword.put(fields, :detail, detail))]
  end

  defp check_cell({key, channel, locale, cell}, ctx) do
    markup = markup(channel, locale, cell, ctx.compiled)
    options = [allow_raw: ctx.definition["allow_raw"] == true, html: markup]
    {parsed, errors} = CellRender.parse(channel, cell, options)
    templates = Map.new(parsed, fn {pointer, {_part, template}} -> {pointer, template} end)
    reads = templates |> Map.values() |> Enum.flat_map(&Variables.reads/1)
    texts = templates |> Map.values() |> Enum.flat_map(&Walk.texts/1)
    where = %{channel: channel, locale: locale}
    static = static_findings(where, cell, templates, errors, texts, ctx)
    worst = worst(where, cell, parsed, ctx, static, markup)

    %{
      key: key,
      channel: channel,
      locale: locale,
      texts: texts,
      paths: Enum.map(reads, & &1.path),
      required: required(reads, ctx),
      reads: reads,
      findings: static ++ worst.findings,
      measures: worst.measures,
      lock_screen: lock_screen_texts(channel, templates, ctx.definition)
    }
  end

  defp markup(:email, locale, cell, compiled) do
    if mjml?(cell), do: Map.get(compiled, locale)
  end

  defp markup(_channel, _locale, _cell, _compiled), do: nil

  defp worst(where, cell, parsed, ctx, static, markup) do
    if renderable?(where.channel, cell, markup) and not Enum.any?(static, &blocks_render?/1),
      do: worst_case(where, cell, parsed, ctx),
      else: %{findings: [], measures: nil}
  end

  defp renderable?(:email, cell, markup), do: not mjml?(cell) or markup != nil
  defp renderable?(_channel, _cell, _markup), do: true

  # TP-61
  defp bound_partial?("partial." <> key, :any), do: not String.contains?(key, ".")
  defp bound_partial?("partial." <> key, partials) when is_list(partials), do: key in partials
  defp bound_partial?(_path, _partials), do: false

  # TP-62
  defp required(reads, ctx) do
    for %{path: path, segments: [root | _]} <- reads,
        root not in @not_required,
        Enum.all?(ctx.optional, &(not Map.has_key?(&1, path))),
        into: MapSet.new(),
        do: path
  end

  defp blocks_render?(%{level: :hard, check: check}),
    do: check in [:parse, :variables, :icu_categories]

  defp blocks_render?(_finding), do: false

  defp static_findings(where, cell, templates, errors, texts, ctx) do
    promotion =
      Promotion.check(texts, Map.get(ctx.input, :promotional_terms, []),
        message_class: ctx.input.message_class,
        locale: where.locale,
        channel: where.channel
      )

    parse_findings(errors, where) ++
      variable_findings(templates, ctx.schemas, where, @helpers, ctx.partials) ++
      icu_findings(templates, where) ++ channel_static(where, cell, templates) ++ promotion
  end

  defp parse_findings(errors, where) do
    for {pointer, found} <- errors, finding <- found do
      detail = %{code: finding.code, message: finding.detail, line: finding.line}
      Finding.new(:parse, :hard, fields(where, pointer, detail))
    end
  end

  defp fields(where, pointer, detail),
    do: [channel: where.channel, locale: where.locale, pointer: pointer, detail: detail]

  # TP-13
  # TP-14
  defp variable_findings(templates, schemas, where, helpers, partials) do
    for {pointer, template} <- templates,
        schema <- schemas,
        finding <- Variables.validate(template, schema, helpers: helpers),
        not bound_partial?(finding.path, partials) do
      level = if finding.severity == :error, do: :hard, else: :warning
      detail = %{code: finding.code, path: finding.path, message: finding.detail}
      Finding.new(:variables, level, fields(where, pointer, detail))
    end
  end

  # TP-59
  defp icu_findings(templates, where) do
    for {pointer, template} <- templates,
        message <- Walk.icu_messages(template),
        missing = Filters.icu_categories_missing(message, where.locale),
        missing != [] do
      Finding.new(:icu_categories, :hard, fields(where, pointer, %{missing: missing}))
    end
  end

  # TP-19
  defp channel_static(%{channel: :sms, locale: locale}, _cell, templates) do
    case Map.fetch(templates, "/body") do
      {:ok, template} ->
        Content.template_findings(Enum.join(Walk.texts(template), " "), locale: locale)

      :error ->
        []
    end
  end

  # TP-22
  defp channel_static(%{channel: :email} = where, cell, _templates) do
    if String.trim(cell["text"] || "") == "",
      do: [Finding.new(:email_plain_text, :hard, fields(where, "/text", %{}))],
      else: []
  end

  defp channel_static(_where, _cell, _templates), do: []

  defp lock_screen_texts(channel, templates, definition) when channel in [:push, :web_push] do
    keys =
      if definition["sensitivity"] == "sensitive",
        do: ["title", "subtitle", "lock_screen_body"],
        else: ["title", "subtitle", "body"]

    for key <- keys, {:ok, template} <- [Map.fetch(templates, "/" <> key)], into: %{} do
      {key, Enum.join(Walk.texts(template), " ")}
    end
  end

  defp lock_screen_texts(_channel, _templates, _definition), do: %{}

  # TP-15
  # TP-20
  # TP-38
  defp worst_case(where, cell, parsed, ctx) do
    renders =
      for schema <- ctx.schemas,
          {name, data} <- Samples.boundary(schema),
          sample?(where.channel, name) do
        {name, render_sample(where, cell, parsed, data, schema, ctx)}
      end

    findings = renders |> Enum.flat_map(&sample_findings(where, &1)) |> widest_segments()
    lint = lint_findings(where, renders)
    %{findings: findings ++ lint, measures: worst_measures(where, renders)}
  end

  defp widest_segments(findings) do
    {segments, others} = Enum.split_with(findings, &(&1.check == :sms_segments))

    case segments do
      [] -> others
      found -> others ++ [Enum.max_by(found, & &1.detail.segments)]
    end
  end

  defp sample?(:sms, name), do: name in @sms_samples
  defp sample?(_channel, _name), do: true

  defp render_sample(where, cell, parsed, data, schema, ctx) do
    CellRender.cell(where.channel, cell, parsed,
      locale: where.locale,
      time_zone: "Etc/UTC",
      data: partial_data(data, ctx.partials),
      brand: Map.get(ctx.input, :brand, %{}),
      helpers: sample_helpers(),
      variables: Variables.criticality(schema),
      sensitivity: CellRender.sensitivity(ctx.definition["sensitivity"]),
      sms_policy: CellRender.policy(ctx.definition["sms_encoding"]),
      message_class: ctx.input.message_class,
      limits: @worst_limits
    )
  end

  # TP-61
  defp partial_data(data, []), do: data
  defp partial_data(data, keys), do: Map.put(data, "partial", Map.new(keys, &{&1, ""}))

  defp sample_helpers,
    do: %{"legal_footer" => "", "unsubscribe_url" => "https://unsubscribe.invalid/0000000000"}

  defp sample_findings(where, {name, {:error, reason, variable}}) do
    detail = %{sample: name, reason: Atom.to_string(reason), variable: variable}
    [Finding.new(:worst_case_render, :hard, fields(where, nil, detail))]
  end

  defp sample_findings(%{channel: :sms} = where, {_name, {:ok, result}}) do
    findings = Enum.reject(result.findings, &(&1.check == :sms_segments))

    if result.sms.segments > @sms_segments do
      sms = result.sms
      detail = %{segments: sms.segments, limit: @sms_segments, encoding: sms.encoding}
      findings ++ [Finding.new(:sms_segments, :warning, fields(where, "/body", detail))]
    else
      findings
    end
  end

  defp sample_findings(_where, {_name, {:ok, result}}), do: result.findings

  # TP-34
  defp lint_findings(where, renders) do
    case List.keyfind(renders, @lint_sample, 0) do
      {_name, {:ok, %{content: content}}} when is_map(content) -> lint(where, content)
      _other -> []
    end
  end

  defp lint(%{channel: :email, locale: locale}, content),
    do: Accessibility.email(content, locale: locale)

  defp lint(%{channel: channel, locale: locale}, content)
       when channel in [:push, :web_push, :sms, :in_app] do
    body = content["body"] || ""
    Accessibility.first_line(body, channel: channel, locale: locale, pointer: "/body")
  end

  defp lint(_where, _content), do: []

  defp worst_measures(where, renders) do
    ok = for {name, {:ok, result}} <- renders, do: {name, result}

    case Enum.max_by(ok, fn {_name, result} -> result.measures.bytes end, fn -> nil end) do
      nil -> nil
      {name, result} -> measure(where.channel, name, result, ok)
    end
  end

  defp measure(:sms, name, result, ok) do
    {_name, widest} = Enum.max_by(ok, fn {_name, result} -> result.sms.segments end)

    result.measures
    |> Map.put(:sample, name)
    |> Map.put(:sms, widest.sms)
  end

  defp measure(_channel, name, result, _ok), do: Map.put(result.measures, :sample, name)

  # TP-21
  # TP-46
  defp sensitivity_findings(results, definition, input) do
    class =
      if CellRender.sensitivity(definition["sensitivity"]),
        do: [],
        else: [Finding.new(:sensitivity_missing, :hard)]

    approved = approved_terms(definition)
    entries = Map.get(input, :sensitive_terms, [])

    terms =
      results
      |> Enum.group_by(& &1.locale)
      |> Enum.sort()
      |> Enum.flat_map(fn {locale, group} ->
        texts = Enum.flat_map(group, & &1.texts)
        paths = group |> Enum.flat_map(& &1.paths) |> Enum.uniq()
        found = Sensitive.matches(texts, paths, entries, locale)
        unconfirmed = Enum.reject(found, &(&1.term in approved))
        term_finding(unconfirmed, locale) ++ lock_screen(group, entries, locale)
      end)

    class ++ terms
  end

  defp approved_terms(%{"sensitivity_approval" => %{"matched_terms" => terms}})
       when is_list(terms),
       do: terms

  defp approved_terms(_definition), do: []

  defp term_finding([], _locale), do: []

  defp term_finding(found, locale),
    do: [Finding.new(:sensitive_terms, :hard, locale: locale, detail: %{terms: found})]

  defp lock_screen(group, entries, locale) do
    Enum.flat_map(group, fn result ->
      opts = [channel: result.channel, locale: locale]
      Accessibility.lock_screen(result.lock_screen, entries, opts)
    end)
  end

  # TP-21
  # TP-46
  @doc "The sensitive dataset terms that match a definition's static texts and variable names, by locale, for the tenant to confirm."
  @spec sensitive_matches(map(), [map()]) :: %{String.t() => [map()]}
  def sensitive_matches(definition, entries) do
    allow_raw = definition["allow_raw"] == true

    definition
    |> cells()
    |> Enum.map(fn {_key, channel, locale, cell} ->
      {parsed, _errors} = CellRender.parse(channel, cell, allow_raw: allow_raw)
      templates = Enum.map(parsed, fn {_pointer, {_part, template}} -> template end)
      paths = for template <- templates, read <- Variables.reads(template), do: read.path
      {locale, Enum.flat_map(templates, &Walk.texts/1), paths}
    end)
    |> Enum.group_by(&elem(&1, 0))
    |> Map.new(fn {locale, rows} ->
      texts = Enum.flat_map(rows, &elem(&1, 1))
      paths = rows |> Enum.flat_map(&elem(&1, 2)) |> Enum.uniq()
      {locale, Sensitive.matches(texts, paths, entries, locale)}
    end)
  end

  # TP-33
  # TP-55
  defp legal_findings(results, input) do
    variants =
      for result <- results do
        helpers = for read <- result.reads, read.path in @helpers, uniq: true, do: read.path
        opt_out = if "legal_footer" in helpers, do: "legal_footer"
        %{channel: result.channel, locale: result.locale, helpers: helpers, opt_out: opt_out}
      end

    brand = Map.get(input, :brand, %{})
    opts = [message_class: input.message_class, country: Map.get(input, :country)]
    LegalFooter.check(variants, brand, opts)
  end

  defp locale_set_findings(results) do
    results
    |> Enum.group_by(& &1.channel)
    |> Enum.sort()
    |> Enum.flat_map(fn {channel, group} ->
      sets = Map.new(group, fn result -> {result.locale, MapSet.new(result.paths)} end)
      union = sets |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2)
      required = group |> Enum.map(& &1.required) |> Enum.reduce(MapSet.new(), &MapSet.union/2)

      missing =
        for {locale, set} <- sets,
            difference = MapSet.difference(union, set),
            MapSet.size(difference) > 0,
            into: %{},
            do: {locale, difference |> MapSet.to_list() |> Enum.sort()}

      {hard, soft} = split_missing(missing, required)

      locale_set_finding(:locale_required_variables, :hard, channel, hard) ++
        locale_set_finding(:locale_variables, :warning, channel, soft)
    end)
  end

  # TP-62
  defp split_missing(missing, required) do
    Enum.reduce(missing, {%{}, %{}}, fn {locale, paths}, {hard, soft} ->
      {needed, other} = Enum.split_with(paths, &MapSet.member?(required, &1))
      {put_present(hard, locale, needed), put_present(soft, locale, other)}
    end)
  end

  defp put_present(map, _locale, []), do: map
  defp put_present(map, locale, paths), do: Map.put(map, locale, paths)

  defp locale_set_finding(_check, _level, _channel, missing) when missing == %{}, do: []

  defp locale_set_finding(check, level, channel, missing),
    do: [Finding.new(check, level, channel: channel, detail: %{missing: missing})]

  # TP-17
  defp usage(results) do
    reads = Enum.flat_map(results, & &1.reads)
    always = for %{guarded: false, path: path} <- reads, uniq: true, do: path
    conditional = for %{guarded: true, path: path} <- reads, uniq: true, do: path
    %{"always" => Enum.sort(always), "conditional" => Enum.sort(conditional -- always)}
  end

  defp measures(results) do
    Enum.reduce(results, %{}, fn
      %{measures: nil}, acc ->
        acc

      %{key: key, locale: locale, measures: measures}, acc ->
        Map.update(acc, key, %{locale => measures}, &Map.put(&1, locale, measures))
    end)
  end

  # TP-8
  # TP-35
  # TP-58
  @doc "Runs the gate over a layout definition: the MJML compiles and declares its icons, and the compiled HTML and the plain text header and footer parse and read only brand fields and the render helpers `legal_footer`, `unsubscribe_url` and `content` (the template's body). Options: `:compile`."
  @spec layout(map(), keyword()) :: %{findings: [Finding.t()], compiled: String.t() | nil}
  def layout(definition, opts \\ []) do
    compile = Keyword.get(opts, :compile)
    {html, mjml} = compile_one(definition["mjml"] || "", compile, pointer: "/mjml")
    texts = for key <- ["text_header", "text_footer"], do: {"/" <> key, definition[key]}
    sources = if html, do: texts ++ [{"/mjml", html}], else: texts

    findings =
      for {pointer, text} <- sources,
          is_binary(text),
          finding <- layout_source(pointer, text),
          do: finding

    %{findings: mjml ++ findings, compiled: html}
  end

  defp layout_source(pointer, text) do
    where = %{channel: nil, locale: nil}

    case Engine.parse(text) do
      {:ok, template} ->
        variable_findings(%{pointer => template}, [@empty_schema], where, @layout_helpers, :any)

      {:error, found} ->
        parse_findings([{pointer, found}], where)
    end
  end

  # TP-35
  # TP-59
  @doc "Runs the gate over a partial definition: every locale body is in a supported locale, parses within the static limits and has every ICU plural and select form of its locale. Options: `:supported_locales`."
  @spec partial(map(), keyword()) :: %{findings: [Finding.t()]}
  def partial(definition, opts \\ []) do
    supported = Keyword.get(opts, :supported_locales, Cldr.supported_locales())
    bodies = Enum.sort(Map.get(definition, "bodies") || %{})
    locales = [definition["default_locale"] | Enum.map(bodies, &elem(&1, 0))]

    body_findings =
      Enum.flat_map(bodies, fn {locale, body} ->
        where = %{channel: nil, locale: locale}
        pointer = "/bodies/" <> locale

        case Engine.parse(body) do
          {:ok, template} -> partial_body(template, pointer, where)
          {:error, found} -> parse_findings([{pointer, found}], where)
        end
      end)

    %{findings: locale_findings(locales, supported) ++ body_findings}
  end

  defp partial_body(template, pointer, where),
    do: nested_partials(template, pointer, where) ++ icu_findings(%{pointer => template}, where)

  # TP-61
  defp nested_partials(template, pointer, where) do
    for %{path: path, segments: ["partial" | _]} <- Variables.reads(template), uniq: true do
      detail = %{code: "partial_in_partial", path: path, message: "a partial reads no partial"}
      Finding.new(:variables, :hard, fields(where, pointer, detail))
    end
  end
end
