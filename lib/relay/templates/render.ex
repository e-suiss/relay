defmodule Relay.Templates.Render do
  @moduledoc """
  The render of one pinned template cell for one channel on the send path (TP-50). Every part of the cell is parsed and rendered in the bounded sandbox (`Relay.Templates.Sandbox`) with a context built for the channel and the part's escaping mode, then handed to the channel's output module: SMS through `Relay.Templates.Sms.plan/2` with the template's encoding policy, push with the sensitivity class (a `sensitive` template shows only `lock_screen_body`), e-mail with subject, preheader, HTML and plain text, WhatsApp through the parameter cleaner, the inbox as structured fields and webhook as a JSON body. The `href` of the event's `primary` link is the push tap target and the inbox item's target, as the output's `url` (E-83). A channel without an output module of its own renders every text field of its cell as plain text.

  E-mail HTML comes from the cell's `raw_html` source or, for an MJML cell, from the HTML compiled at publication (`compiled_html`); MJML is never compiled here (TP-8). Each pinned partial is rendered first with the same context, which has no `partial` variable, so a partial cannot read another, and its output is inserted unescaped as `partial.<key>` (TP-61). A pinned e-mail layout wraps the rendered HTML through its compiled HTML, where the helper `content_for_layout` holds the template's HTML, and its `text_header` and `text_footer` around the plain text.

  The result is the output, its SHA-256 digest over the canonical JSON of the channel, locale and output, the canonical JSON itself (the content snapshot) and the measures (TP-49): characters, graphemes, bytes and blankness per part, the fallback variables, the sanitizer changes, warnings and the SMS encoding and segments. Measures carry no content. A failure is one of `:missing_variable`, `:render_timeout`, `:output_too_large` and `:schema_violation` with a detail of codes and names only (TP-41).
  """

  alias Relay.Templates.Channel.Email
  alias Relay.Templates.Channel.Inbox
  alias Relay.Templates.Channel.Push
  alias Relay.Templates.Channel.Webhook
  alias Relay.Templates.Channel.Whatsapp
  alias Relay.Templates.Context
  alias Relay.Templates.Engine
  alias Relay.Templates.Sandbox
  alias Relay.Templates.Sms
  alias Relay.Templates.Variables

  @type reason :: :missing_variable | :render_timeout | :output_too_large | :schema_violation
  @type input :: %{
          required(:channel) => Context.channel(),
          required(:cell) => map(),
          required(:locale) => String.t(),
          required(:time_zone) => String.t(),
          required(:data) => map(),
          optional(:recipient) => map(),
          optional(:brand) => map(),
          optional(:links) => %{String.t() => String.t()},
          optional(:helpers) => map(),
          optional(:event_schema) => map() | nil,
          optional(:schema) => JSV.Root.t() | nil,
          optional(:sensitivity) => :public | :personal | :sensitive,
          optional(:sms_encoding) => :transliterate | :turkish_shift | :ucs2,
          optional(:message_class) => String.t(),
          optional(:allow_raw) => boolean(),
          optional(:layout) => map() | nil,
          optional(:partials) => %{String.t() => String.t() | nil},
          optional(:sandbox) => keyword()
        }
  @type rendered :: %{
          output: map(),
          content: binary(),
          digest: <<_::256>>,
          measures: map()
        }

  @text_channels [:voice, :slack, :teams, :telegram, :discord]
  @push_fields ~w(title subtitle body lock_screen_body in_app_body)
  @meta_fields ~w(machine_translated translation_approved_by)
  @too_large ~w(push_payload_size push_characters email_html_size)a
  @slot "content_for_layout"
  @partial "partial"

  # TP-7
  # TP-24
  # TP-41
  # TP-49
  # TP-50
  # INV-46
  @doc "Renders one cell; see the module documentation."
  @spec run(input()) :: {:ok, rendered()} | {:error, reason(), map()}
  def run(%{channel: channel} = input) do
    state = %{input: input, contexts: %{}, parts: %{}, fallbacks: []}

    with {:ok, output, extra, state} <- channel(channel, input.cell, state) do
      {:ok, finish(input, output, extra, state)}
    end
  end

  defp finish(input, output, extra, state) do
    channel = Atom.to_string(input.channel)
    document = %{"channel" => channel, "locale" => input.locale, "output" => output}
    content = canonical_json(document)

    base = %{
      "channel" => channel,
      "locale" => input.locale,
      "parts" => state.parts,
      "fallbacks" => length(state.fallbacks),
      "fallback_variables" => Enum.uniq(state.fallbacks),
      "changes" => [],
      "warnings" => []
    }

    measures = Map.merge(base, extra)

    %{
      output: output,
      content: content,
      digest: :crypto.hash(:sha256, content),
      measures: measures
    }
  end

  # TP-18
  # TP-53
  defp channel(:sms, cell, state) do
    with {:ok, body, state} <- part(state, "body", string(cell, "body"), :text) do
      policy = Map.get(state.input, :sms_encoding, :turkish_shift)
      class = Map.get(state.input, :message_class, "")
      plan = Sms.plan(body, policy: policy, message_class: class)

      if String.trim(plan.text) == "" do
        violation("blank_output")
      else
        output = %{"text" => plan.text, "encoding" => plan.name, "segments" => plan.segments}
        {:ok, output, Map.put(sms_measures(plan), "changes", changes(plan.changes)), state}
      end
    end
  end

  # TP-20
  # TP-21
  defp channel(channel, cell, state) when channel in [:push, :web_push] do
    with {:ok, fields, state} <- fields(state, cell, @push_fields, :json) do
      sensitivity = Map.get(state.input, :sensitivity, :personal)

      case Push.render(fields, sensitivity, locale: state.input.locale) do
        {:ok, %{output: out, changes: changes}} ->
          output = %{
            "title" => out.title,
            "subtitle" => out.subtitle,
            "body" => out.body,
            "in_app_body" => out.in_app_body,
            "payload" => out.payload
          }

          output = target(output, state.input)
          {:ok, output, %{"bytes" => out.bytes, "changes" => changes(changes)}, state}

        {:error, findings} ->
          findings(findings)
      end
    end
  end

  # TP-8
  # TP-22
  # TP-35
  defp channel(:email, cell, state) do
    with {:ok, source} <- email_source(cell),
         {:ok, subject, state} <- part(state, "subject", string(cell, "subject"), :text),
         {:ok, preheader, state} <- part(state, "preheader", string(cell, "preheader"), :text),
         {:ok, html, state} <- part(state, "html", source, :html),
         {:ok, text, state} <- part(state, "text", string(cell, "text"), :text),
         {:ok, html, text, state} <- layout(state, Map.get(state.input, :layout), html, text) do
      fields = %{"subject" => subject, "preheader" => preheader, "html" => html, "text" => text}
      email(Email.render(fields, locale: state.input.locale), state)
    end
  end

  # TP-23
  defp channel(:whatsapp, cell, state) do
    parameters = if is_list(cell["parameters"]), do: cell["parameters"], else: []

    with {:ok, rendered, state} <- parameters(state, parameters) do
      {values, changes} = Whatsapp.clean_all(Enum.map(rendered, fn {_name, v} -> {:body, v} end))

      cleaned =
        for {{name, _raw}, value} <- Enum.zip(rendered, values),
            do: %{"name" => name, "value" => value}

      output = %{
        "template_name" => string(cell, "template_name"),
        "language" => cell["language"] || state.input.locale,
        "parameters" => cleaned
      }

      {:ok, output, %{"changes" => changes(changes)}, state}
    end
  end

  # TP-9
  # TP-24
  defp channel(:in_app, cell, state) do
    actions = if is_list(cell["actions"]), do: cell["actions"], else: []

    with {:ok, fields, state} <- fields(state, cell, ~w(title body avatar_url), :structured),
         {:ok, actions, state} <- actions(state, actions) do
      fields =
        fields
        |> Map.put("avatar", fields["avatar_url"])
        |> Map.delete("avatar_url")
        |> Map.put("actions", actions)

      case Inbox.render(fields, locale: state.input.locale) do
        {:ok, %{output: out, changes: changes}} ->
          {:ok, target(inbox(out), state.input), changes_of(changes), state}

        {:error, findings} ->
          findings(findings)
      end
    end
  end

  # TP-9
  # TP-24
  defp channel(:webhook, cell, state) do
    with {:ok, body, state} <- part(state, "body", string(cell, "body"), :json) do
      case Webhook.render(body, locale: state.input.locale) do
        {:ok, %{output: out}} -> {:ok, %{"body" => out.body}, %{"bytes" => out.bytes}, state}
        {:error, findings} -> findings(findings)
      end
    end
  end

  defp channel(channel, cell, state) when channel in @text_channels do
    keys = for {key, value} <- cell, is_binary(value), key not in @meta_fields, do: key

    with {:ok, fields, state} <- fields(state, cell, Enum.sort(keys), :text) do
      if Enum.all?(Map.values(fields), &blank?/1),
        do: violation("blank_output"),
        else: {:ok, fields, %{}, state}
    end
  end

  defp blank?(value), do: String.trim(value) == ""

  defp email({:ok, %{output: out, changes: changes, findings: warnings}}, state) do
    output = %{
      "subject" => out.subject,
      "subject_header" => out.subject_header,
      "preheader" => out.preheader,
      "html" => out.html,
      "text" => out.text
    }

    extra = %{
      "html_bytes" => out.html_bytes,
      "changes" => changes(changes),
      "warnings" => Enum.map(warnings, &Atom.to_string(&1.check))
    }

    {:ok, output, extra, state}
  end

  defp email({:error, findings}, _state), do: findings(findings)

  defp inbox(out) do
    %{
      "title" => out.title,
      "body" => out.body,
      "actions" => Enum.map(out.actions, &%{"label" => &1.label, "url" => &1.url}),
      "avatar" => out.avatar,
      "locale" => out.locale,
      "dir" => out.dir
    }
  end

  defp changes_of(changes), do: %{"changes" => changes(changes)}

  # E-83
  defp target(output, input) do
    case input |> Map.get(:links, %{}) |> Map.get("primary") do
      url when is_binary(url) -> Map.put(output, "url", url)
      _none -> output
    end
  end

  # TP-8
  defp email_source(cell) do
    case {cell["html_kind"] || "mjml", cell} do
      {"raw_html", %{"html" => html}} when is_binary(html) -> {:ok, html}
      {"mjml", %{"compiled_html" => html}} when is_binary(html) -> {:ok, html}
      _no_html -> violation("compiled_html_missing")
    end
  end

  # TP-35
  defp layout(state, nil, html, text), do: {:ok, html, text, state}

  defp layout(state, content, html, text) when is_map(content) do
    header = string(content, "text_header")
    footer = string(content, "text_footer")

    with {:ok, source} <- layout_html(content),
         {:ok, wrapped, state} <- part(state, "layout_html", source, :html, %{@slot => html}),
         {:ok, header, state} <- part(state, "layout_text_header", header, :text),
         {:ok, footer, state} <- part(state, "layout_text_footer", footer, :text) do
      text = [header, text, footer] |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")
      {:ok, wrapped, text, state}
    end
  end

  defp layout_html(%{"compiled_html" => html}) when is_binary(html), do: {:ok, html}
  defp layout_html(_content), do: violation("layout_compiled_html_missing")

  defp fields(state, cell, keys, escape) do
    keys
    |> Enum.filter(&is_binary(cell[&1]))
    |> Enum.reduce_while({:ok, %{}, state}, fn key, {:ok, acc, state} ->
      case part(state, key, cell[key], escape) do
        {:ok, value, state} -> {:cont, {:ok, Map.put(acc, key, value), state}}
        error -> {:halt, error}
      end
    end)
  end

  defp parameters(state, parameters) do
    parameters
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], state}, fn {parameter, index}, {:ok, acc, state} ->
      name = if is_map(parameter), do: parameter["name"], else: nil
      source = if is_map(parameter), do: parameter["value"], else: nil

      case part(state, "parameters/#{index}", source, :text) do
        {:ok, value, state} -> {:cont, {:ok, acc ++ [{name, value}], state}}
        error -> {:halt, error}
      end
    end)
  end

  defp actions(state, actions) do
    actions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], state}, fn {action, index}, {:ok, acc, state} ->
      action = if is_map(action), do: action, else: %{}
      path = "actions/#{index}"

      with {:ok, label, state} <- part(state, path <> "/label", action["label"], :structured),
           {:ok, url, state} <- part(state, path <> "/url", action["url"], :structured) do
        {:cont, {:ok, acc ++ [%{"label" => label, "url" => url}], state}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp part(state, name, source, escape, extra \\ %{})

  defp part(state, _name, nil, _escape, _extra), do: {:ok, "", state}

  defp part(state, name, source, escape, extra) when is_binary(source) do
    with {:ok, template} <- parse(source, Map.get(state.input, :allow_raw, false)),
         {:ok, context, state} <- context(state, escape, extra),
         {:ok, output, measures} <- sandbox(template, context, state.input) do
      parts = Map.put(state.parts, name, part_measures(measures))
      fallbacks = state.fallbacks ++ measures.fallback_variables
      {:ok, output, %{state | parts: parts, fallbacks: fallbacks}}
    end
  end

  defp part(_state, _name, _source, _escape, _extra), do: violation("cell_invalid")

  defp parse(source, allow_raw) do
    case Engine.parse(source, allow_raw: allow_raw) do
      {:ok, template} -> {:ok, template}
      {:error, _findings} -> violation("template_invalid")
    end
  end

  defp sandbox(template, context, input) do
    case Sandbox.run(template, context, input.channel, Map.get(input, :sandbox, [])) do
      {:ok, output, measures} -> {:ok, output, measures}
      {:error, :render_timeout} -> {:error, :render_timeout, %{}}
      {:error, :output_too_large} -> {:error, :output_too_large, %{}}
      {:error, {:missing_variable, name}} -> {:error, :missing_variable, %{"variable" => name}}
      {:error, {:schema_violation, _detail}} -> violation("render")
    end
  end

  # TP-5
  # TP-14
  defp context(state, escape, extra) when extra == %{} do
    case Map.fetch(state.contexts, escape) do
      {:ok, context} ->
        {:ok, context, state}

      :error ->
        with {:ok, context} <- build(state.input, escape, %{}) do
          {:ok, context, %{state | contexts: Map.put(state.contexts, escape, context)}}
        end
    end
  end

  defp context(state, escape, extra) do
    with {:ok, context} <- build(state.input, escape, extra), do: {:ok, context, state}
  end

  defp build(input, escape, extra) do
    helpers =
      input
      |> Map.get(:helpers, %{})
      |> Map.merge(Map.new(extra, fn {name, value} -> {name, {:trusted, value}} end))

    fields = [
      locale: input.locale,
      time_zone: input.time_zone,
      data: input.data,
      recipient: Map.get(input, :recipient, %{}),
      brand: Map.get(input, :brand, %{}),
      links: Map.get(input, :links, %{}),
      helpers: helpers,
      variables: criticality(Map.get(input, :event_schema)),
      schema: Map.get(input, :schema),
      escape: escape
    ]

    with :ok <- partial_name(input.data),
         {:ok, context} <- new_context(input.channel, fields) do
      with_partials(context, input)
    end
  end

  defp new_context(channel, fields) do
    case Context.new(channel, fields) do
      {:ok, context} -> {:ok, context}
      {:error, {:schema_violation, _detail}} -> violation("context")
    end
  end

  # TP-61
  defp partial_name(data) when is_map_key(data, @partial), do: violation("context")
  defp partial_name(_data), do: :ok

  # TP-35
  # TP-61
  defp with_partials(context, input) do
    input
    |> Map.get(:partials, %{})
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn {key, source}, {:ok, acc} ->
      case partial(context, input, source) do
        {:ok, output} -> {:cont, {:ok, Map.put(acc, key, output)}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rendered} when rendered == %{} -> {:ok, context}
      {:ok, rendered} -> {:ok, %{context | vars: Map.put(context.vars, @partial, rendered)}}
      error -> error
    end
  end

  defp partial(_context, _input, nil), do: violation("partial_locale_missing")

  defp partial(context, input, source) when is_binary(source) do
    with {:ok, template} <- parse(source, Map.get(input, :allow_raw, false)),
         {:ok, output, _measures} <- sandbox(template, context, input),
         do: {:ok, output}
  end

  defp criticality(schema) when is_map(schema), do: Variables.criticality(schema)
  defp criticality(_schema), do: %{}

  defp part_measures(measures) do
    %{
      "characters" => measures.characters,
      "graphemes" => measures.graphemes,
      "bytes" => measures.bytes,
      "blank" => measures.blank
    }
  end

  defp sms_measures(plan) do
    %{
      "sms" => %{
        "encoding" => plan.name,
        "segments" => plan.segments,
        "units" => plan.units,
        "characters" => plan.characters,
        "emoji" => plan.emoji,
        "unverified" => %{
          "encoding" => plan.unverified.name,
          "segments" => plan.unverified.segments
        }
      }
    }
  end

  # INV-1
  defp changes(changes) do
    for change <- changes do
      %{
        "rule" => Atom.to_string(change.rule),
        "action" => Atom.to_string(change.action),
        "field" => change.field,
        "count" => change.count
      }
    end
  end

  # INV-46
  defp findings(findings) do
    checks = for %{level: :hard, check: check} <- findings, uniq: true, do: check

    reason =
      if Enum.any?(checks, &(&1 in @too_large)), do: :output_too_large, else: :schema_violation

    {:error, reason, %{"cause" => "output", "checks" => Enum.map(checks, &Atom.to_string/1)}}
  end

  defp violation(cause), do: {:error, :schema_violation, %{"cause" => cause}}

  defp string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _absent -> nil
    end
  end

  @doc "Encodes a JSON value with its object keys sorted, so the same value has one encoding."
  @spec canonical_json(term()) :: binary()
  def canonical_json(value), do: value |> order() |> Jason.encode!()

  defp order(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, order(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp order(list) when is_list(list), do: Enum.map(list, &order/1)
  defp order(value), do: value
end
