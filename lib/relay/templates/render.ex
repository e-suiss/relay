defmodule Relay.Templates.Render do
  @moduledoc """
  Renders one cell of a template definition (one channel in one locale) with given data, the way the publication gate and the preview do (TP-32, TP-38, API-60).

  A cell is the JSON object of a channel variant (`SmsCell`, `PushCell`, `EmailCell`, `WhatsappCell`, `InboxCell`, `WebhookCell` of the contract). `fields/2` lists its Liquid sources by JSON Pointer; `parse/3` parses them with the template's `allow_raw` flag and, for an MJML email, the HTML compiled at publication in place of the MJML source (TP-8). `cell/4` renders every field in its own bounded process with a context built for the channel and the field's part (`Relay.Templates.Sandbox`), then assembles the channel output: the SMS plan with its encoding and segments on a planned and an unverified provider (TP-18, TP-53), the push payload (TP-20, TP-21), the email fields (TP-22), the cleaned WhatsApp parameters (TP-23), the structured inbox payload and the webhook JSON body. A missing required variable, a time-out or an oversized output is a failure, never a cut output (TP-41).
  """

  alias Relay.Templates.Channel.Email
  alias Relay.Templates.Channel.Inbox
  alias Relay.Templates.Channel.Push
  alias Relay.Templates.Channel.Webhook
  alias Relay.Templates.Channel.Whatsapp
  alias Relay.Templates.Context
  alias Relay.Templates.Engine
  alias Relay.Templates.Finding
  alias Relay.Templates.Sandbox
  alias Relay.Templates.Sms
  alias Relay.Templates.Sms.Encoding

  @type field :: {String.t(), Context.part(), String.t()}
  @type measures :: %{
          characters: non_neg_integer(),
          bytes: non_neg_integer(),
          graphemes: non_neg_integer()
        }
  @type parsed :: %{String.t() => {Context.part(), Engine.t()}}
  @type failure :: :missing_variable | :render_timeout | :output_too_large | :schema_violation
  @type result :: %{
          content: map(),
          measures: measures(),
          sms: map() | nil,
          findings: [Finding.t()]
        }

  @channels %{
    "sms" => :sms,
    "push" => :push,
    "web_push" => :web_push,
    "email" => :email,
    "whatsapp" => :whatsapp,
    "in_app" => :in_app,
    "webhook" => :webhook
  }
  @push_fields ~w(title subtitle body lock_screen_body in_app_body)
  @email_fields [
    {"subject", :subject},
    {"preheader", :preheader},
    {"html", :html},
    {"text", :text}
  ]
  @policies %{
    "transliterate" => :transliterate,
    "turkish_shift" => :turkish_shift,
    "ucs2" => :ucs2
  }
  @sensitivities %{"public" => :public, "personal" => :personal, "sensitive" => :sensitive}

  # TP-9
  @doc "The channel atom of a cell key of the definition, or `nil` for a key outside the variant model."
  @spec channel(String.t()) :: Context.channel() | nil
  def channel(key), do: Map.get(@channels, key)

  @doc "The cell keys of the variant model."
  @spec channel_keys() :: [String.t()]
  def channel_keys, do: @channels |> Map.keys() |> Enum.sort()

  @doc "The SMS encoding policy atom of a definition's `sms_encoding`; `turkish_shift` by default."
  @spec policy(String.t() | nil) :: Encoding.policy()
  def policy(name), do: Map.get(@policies, name, :turkish_shift)

  @doc "The sensitivity class atom of a definition's `sensitivity`, or `nil`."
  @spec sensitivity(String.t() | nil) :: :public | :personal | :sensitive | nil
  def sensitivity(name), do: Map.get(@sensitivities, name)

  # TP-9
  @doc "The Liquid sources of a cell by JSON Pointer, with the context part each is rendered for."
  @spec fields(Context.channel(), map()) :: [field()]
  def fields(:sms, cell), do: present([{"/body", :body, cell["body"]}])

  def fields(channel, cell) when channel in [:push, :web_push] do
    @push_fields
    |> Enum.map(fn key -> {"/" <> key, push_part(key), cell[key]} end)
    |> present()
  end

  def fields(:email, cell) do
    @email_fields
    |> Enum.map(fn {key, part} -> {"/" <> key, part, cell[key]} end)
    |> present()
  end

  def fields(:whatsapp, cell) do
    cell
    |> list("parameters")
    |> Enum.with_index()
    |> Enum.map(fn {parameter, index} ->
      {"/parameters/#{index}/value", :body, parameter["value"]}
    end)
    |> present()
  end

  def fields(:in_app, cell) do
    actions =
      cell
      |> list("actions")
      |> Enum.with_index()
      |> Enum.flat_map(fn {action, index} ->
        [
          {"/actions/#{index}/label", :body, action["label"]},
          {"/actions/#{index}/url", :body, action["url"]}
        ]
      end)

    present(
      [{"/title", :title, cell["title"]}, {"/body", :body, cell["body"]}] ++
        actions ++ [{"/avatar_url", :body, cell["avatar_url"]}]
    )
  end

  def fields(:webhook, cell), do: present([{"/body", :payload, cell["body"]}])
  def fields(_channel, _cell), do: []

  defp push_part("title"), do: :title
  defp push_part(_key), do: :body

  defp list(cell, key) do
    case cell[key] do
      items when is_list(items) -> Enum.filter(items, &is_map/1)
      _other -> []
    end
  end

  defp present(fields),
    do: Enum.filter(fields, fn {_pointer, _part, source} -> is_binary(source) end)

  # TP-4
  # TP-6
  # TP-8
  @doc "Parses the fields of a cell. Options: `:allow_raw` and `:html`, the compiled HTML that replaces the email `html` source. Returns the parsed fields by pointer and the parse findings by pointer."
  @spec parse(Context.channel(), map(), keyword()) ::
          {parsed(), [{String.t(), [Engine.finding()]}]}
  def parse(channel, cell, opts \\ []) do
    allow_raw = Keyword.get(opts, :allow_raw, false)

    channel
    |> fields(cell)
    |> Enum.map(fn {pointer, part, source} -> {pointer, part, source(pointer, source, opts)} end)
    |> Enum.reduce({%{}, []}, fn {pointer, part, source}, {parsed, errors} ->
      case Engine.parse(source, allow_raw: allow_raw) do
        {:ok, template} -> {Map.put(parsed, pointer, {part, template}), errors}
        {:error, findings} -> {parsed, errors ++ [{pointer, findings}]}
      end
    end)
  end

  defp source("/html", source, opts), do: Keyword.get(opts, :html) || source
  defp source(_pointer, source, _opts), do: source

  # TP-7
  # TP-38
  # TP-41
  @doc """
  Renders the parsed fields of a cell and assembles the channel output.

  Options: `:locale` and `:time_zone` (required), `:data`, `:recipient`, `:brand`, `:helpers`, `:variables` (criticality declarations), `:sensitivity` (a class atom, default `:public`), `:sms_policy`, `:message_class`, `:limits` (sandbox options). A failure returns its reason and, for a missing variable, its name.
  """
  @spec cell(Context.channel(), map(), parsed(), keyword()) ::
          {:ok, result()} | {:error, failure(), String.t() | nil}
  def cell(channel, cell, parsed, opts) do
    with {:ok, rendered} <- render_fields(channel, parsed, opts) do
      assemble(channel, cell, rendered, opts)
    end
  end

  defp render_fields(channel, parsed, opts) do
    context_fields = [
      locale: Keyword.fetch!(opts, :locale),
      time_zone: Keyword.fetch!(opts, :time_zone),
      data: Keyword.get(opts, :data, %{}),
      recipient: Keyword.get(opts, :recipient, %{}),
      brand: Keyword.get(opts, :brand, %{}),
      helpers: Keyword.get(opts, :helpers, %{}),
      variables: Keyword.get(opts, :variables, %{})
    ]

    parsed
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn {pointer, {part, template}}, {:ok, acc} ->
      case render_one(channel, part, template, context_fields, opts) do
        {:ok, output} -> {:cont, {:ok, Map.put(acc, pointer, output)}}
        {:error, reason, name} -> {:halt, {:error, reason, name}}
      end
    end)
  end

  defp render_one(channel, part, template, context_fields, opts) do
    with {:ok, context} <- Context.new(channel, [part: part] ++ context_fields),
         {:ok, output, _measures} <-
           Sandbox.run(template, context, channel, Keyword.get(opts, :limits, [])) do
      {:ok, output}
    else
      {:error, reason} -> failure(reason)
    end
  end

  defp failure({:missing_variable, name}), do: {:error, :missing_variable, name}
  defp failure({:schema_violation, _detail}), do: {:error, :schema_violation, nil}

  defp failure(reason) when reason in [:render_timeout, :output_too_large],
    do: {:error, reason, nil}

  defp assemble(:sms, _cell, rendered, opts) do
    locale = Keyword.get(opts, :locale)

    plan =
      Sms.plan(Map.get(rendered, "/body", ""),
        policy: Keyword.get(opts, :sms_policy, :turkish_shift),
        message_class: Keyword.get(opts, :message_class, "")
      )

    sms = %{
      encoding: plan.name,
      encoding_unverified_provider: plan.unverified.name,
      segments: plan.segments,
      characters: plan.characters
    }

    {:ok,
     %{
       content: %{"body" => plan.text},
       measures: measures(plan.text),
       sms: sms,
       findings: Sms.findings(plan, locale: locale)
     }}
  end

  defp assemble(channel, _cell, rendered, opts) when channel in [:push, :web_push] do
    sensitivity = Keyword.get(opts, :sensitivity) || :public

    case Push.render(by_key(rendered), sensitivity, locale: Keyword.get(opts, :locale)) do
      {:ok, %{output: output}} ->
        content =
          %{"title" => output.title, "subtitle" => output.subtitle, "body" => output.body}
          |> Map.put("in_app_body", output.in_app_body)
          |> Map.reject(fn {_key, value} -> is_nil(value) end)

        {:ok, %{content: content, measures: measures(output.payload), sms: nil, findings: []}}

      {:error, findings} ->
        {:ok, %{content: nil, measures: measures(""), sms: nil, findings: findings}}
    end
  end

  defp assemble(:email, _cell, rendered, opts) do
    case Email.render(by_key(rendered), locale: Keyword.get(opts, :locale)) do
      {:ok, %{output: output, findings: findings}} ->
        content = %{
          "subject" => output.subject,
          "preheader" => output.preheader,
          "html" => output.html,
          "text" => output.text,
          "dir" => output.dir
        }

        {:ok, %{content: content, measures: measures(output.html), sms: nil, findings: findings}}

      {:error, findings} ->
        {:ok, %{content: nil, measures: measures(""), sms: nil, findings: findings}}
    end
  end

  defp assemble(:whatsapp, cell, rendered, opts) do
    locale = Keyword.get(opts, :locale)
    parameters = list(cell, "parameters")

    values =
      parameters
      |> Enum.with_index()
      |> Enum.map(fn {_parameter, index} ->
        {:body, Map.get(rendered, "/parameters/#{index}/value", "")}
      end)

    {clean, changes} = Whatsapp.clean_all(values)

    content = %{
      "template_name" => cell["template_name"],
      "language" => cell["language"],
      "parameters" =>
        parameters
        |> Enum.zip(clean)
        |> Enum.map(fn {parameter, value} -> %{"name" => parameter["name"], "value" => value} end)
    }

    findings =
      for %{rule: :truncated, field: "body/" <> number, detail: detail} <- changes do
        pointer = "/parameters/#{String.to_integer(number) - 1}/value"
        detail = %{graphemes: detail.graphemes, limit: detail.limit}
        fields = [channel: :whatsapp, locale: locale, pointer: pointer, detail: detail]
        Finding.new(:whatsapp_parameter_length, :warning, fields)
      end

    measured = measures(Enum.join(clean, "\n"))
    {:ok, %{content: content, measures: measured, sms: nil, findings: findings}}
  end

  defp assemble(:in_app, cell, rendered, opts) do
    actions =
      cell
      |> list("actions")
      |> Enum.with_index()
      |> Enum.map(fn {_action, index} ->
        %{
          "label" => Map.get(rendered, "/actions/#{index}/label"),
          "url" => Map.get(rendered, "/actions/#{index}/url")
        }
      end)

    fields =
      %{"title" => rendered["/title"], "body" => rendered["/body"], "actions" => actions}
      |> Map.put("avatar", rendered["/avatar_url"])
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    case Inbox.render(fields, locale: Keyword.get(opts, :locale)) do
      {:ok, %{output: output}} ->
        content = %{
          "title" => output.title,
          "body" => output.body,
          "actions" => Enum.map(output.actions, &%{"label" => &1.label, "url" => &1.url}),
          "avatar_url" => output.avatar,
          "locale" => output.locale,
          "dir" => output.dir
        }

        {:ok, %{content: content, measures: measures(output.body), sms: nil, findings: []}}

      {:error, findings} ->
        {:ok, %{content: nil, measures: measures(""), sms: nil, findings: findings}}
    end
  end

  defp assemble(:webhook, _cell, rendered, opts) do
    body = Map.get(rendered, "/body", "")

    case Webhook.render(body, locale: Keyword.get(opts, :locale)) do
      {:ok, %{output: output}} ->
        {:ok,
         %{content: %{"body" => output.data}, measures: measures(body), sms: nil, findings: []}}

      {:error, findings} ->
        {:ok, %{content: nil, measures: measures(body), sms: nil, findings: findings}}
    end
  end

  defp by_key(rendered), do: Map.new(rendered, fn {"/" <> key, value} -> {key, value} end)

  # TP-7
  @doc "The character (code point), byte and grapheme counts of a text."
  @spec measures(String.t()) :: measures()
  def measures(text) do
    %{
      characters: text |> String.codepoints() |> length(),
      bytes: byte_size(text),
      graphemes: String.length(text)
    }
  end
end
