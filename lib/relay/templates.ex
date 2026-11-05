defmodule Relay.Templates do
  @moduledoc """
  Templates, localisation and rendering. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Templates.CellRender
  alias Relay.Templates.Cldr
  alias Relay.Templates.Context
  alias Relay.Templates.Engine
  alias Relay.Templates.Finding
  alias Relay.Templates.Locale
  alias Relay.Templates.Mjml
  alias Relay.Templates.PublishGate
  alias Relay.Templates.Samples
  alias Relay.Templates.Sandbox
  alias Relay.Templates.Sms
  alias Relay.Templates.TermSets
  alias Relay.Templates.Variables

  @sms_encodings [{"GSM7", :gsm7}, {"GSM7_TR", :gsm7_tr}, {"UCS2", :ucs2}]

  # TP-43
  @doc "Warms the CLDR backend at application start."
  @spec warm_up() :: :ok
  def warm_up, do: Cldr.warm_up()

  # TP-56
  @doc "The supported locales of the CLDR backend."
  @spec supported_locales() :: [String.t()]
  def supported_locales, do: Cldr.supported_locales()

  # TP-4
  # TP-6
  # TP-45
  @doc "Parses a template source; see `Relay.Templates.Engine.parse/2`."
  @spec parse(String.t(), keyword()) :: {:ok, Engine.t()} | {:error, [Engine.finding()]}
  def parse(source, opts \\ []), do: Engine.parse(source, opts)

  # TP-5
  # TP-24
  @doc "Builds the render context of one channel; see `Relay.Templates.Context.new/2`."
  @spec context(Context.channel(), keyword()) :: {:ok, Context.t()} | {:error, Context.error()}
  def context(channel, fields), do: Context.new(channel, fields)

  # TP-7
  # TP-49
  @doc "Renders a parsed template in a bounded process; see `Relay.Templates.Sandbox.run/4`."
  @spec render(Engine.t(), Context.t(), Context.channel(), keyword()) ::
          {:ok, String.t(), Sandbox.measures()} | {:error, Sandbox.reason()}
  def render(template, context, channel, opts \\ []),
    do: Sandbox.run(template, context, channel, opts)

  # TP-17
  @doc "The variable paths a template reads always and conditionally; see `Relay.Templates.Variables.extract/1`."
  @spec variables(Engine.t()) :: Variables.usage()
  def variables(template), do: Variables.extract(template)

  # TP-13
  # TP-14
  @doc "Validates a template's variables against an event schema; see `Relay.Templates.Variables.validate/3`."
  @spec validate_variables(Engine.t(), map(), keyword()) :: [Variables.finding()]
  def validate_variables(template, schema, opts \\ []),
    do: Variables.validate(template, schema, opts)

  # TP-25
  # TP-26
  @doc "Chooses the template cell for a recipient; see `Relay.Templates.Locale.resolve/2`."
  @spec resolve_locale(Locale.candidates(), [String.t()]) ::
          {:ok, Locale.resolution()} | {:error, :locale_missing}
  def resolve_locale(candidates, cells), do: Locale.resolve(candidates, cells)

  # TP-31
  # TP-32
  @doc "Runs the publication gate over a template definition; see `Relay.Templates.PublishGate.template/1`."
  @spec publish_gate(PublishGate.input()) :: PublishGate.result()
  def publish_gate(input), do: PublishGate.template(input)

  # TP-35
  @doc "Runs the publication gate over a layout definition; see `Relay.Templates.PublishGate.layout/2`."
  @spec layout_gate(map(), keyword()) :: %{findings: [Finding.t()], compiled: String.t() | nil}
  def layout_gate(definition, opts \\ []), do: PublishGate.layout(definition, opts)

  # TP-35
  @doc "Runs the publication gate over a partial definition; see `Relay.Templates.PublishGate.partial/2`."
  @spec partial_gate(map(), keyword()) :: %{findings: [Finding.t()]}
  def partial_gate(definition, opts \\ []), do: PublishGate.partial(definition, opts)

  # TP-21
  @doc "The sensitive terms that match a definition, by locale; see `Relay.Templates.PublishGate.sensitive_matches/2`."
  @spec sensitive_matches(map(), [map()]) :: %{String.t() => [map()]}
  defdelegate sensitive_matches(definition, entries), to: PublishGate

  # TP-56
  @doc "Whether a locale is valid and its language is supported by the CLDR backend."
  @spec locale_supported?(term()) :: boolean()
  def locale_supported?(locale) when is_binary(locale),
    do: PublishGate.supported?(locale, Cldr.supported_locales())

  def locale_supported?(_locale), do: false

  # TP-9
  @doc "The cells of a definition as `{channel_key, channel, locale, cell}`; see `Relay.Templates.PublishGate.cells/1`."
  @spec cells(map()) :: [{String.t(), atom(), String.t(), map()}]
  defdelegate cells(definition), to: PublishGate

  # TP-8
  @doc "Compiles MJML at publication or for a preview, never on the send path; see `Relay.Templates.Mjml.compile/2`. The options of `config :relay, Relay.Templates.Mjml` (`:executable`, `:sha256`, `:timeout`, `:max_output`) apply."
  @spec compile_mjml(String.t()) :: {:ok, String.t()} | {:error, Relay.Error.t()}
  def compile_mjml(source) do
    options = Application.get_env(:relay, Mjml, [])
    Mjml.compile(source, Keyword.take(options, [:executable, :sha256, :timeout, :max_output]))
  end

  # TP-38
  # API-60
  @doc "Parses and renders one cell for a channel; see `Relay.Templates.CellRender.parse/3` and `Relay.Templates.CellRender.cell/4`. Returns the parse findings when a field does not parse."
  @spec render_preview(Context.channel(), map(), keyword()) ::
          {:ok, CellRender.result()}
          | {:error, CellRender.failure(), String.t() | nil}
          | {:parse_error, [{String.t(), [Engine.finding()]}]}
  def render_preview(channel, cell, opts) do
    case CellRender.parse(channel, cell, Keyword.take(opts, [:allow_raw, :html])) do
      {parsed, []} -> CellRender.cell(channel, cell, parsed, opts)
      {_parsed, errors} -> {:parse_error, errors}
    end
  end

  # TP-9
  @doc "The channel of a cell key of the definition, or `nil`; see `Relay.Templates.CellRender.channel/1`."
  @spec channel(String.t()) :: Context.channel() | nil
  defdelegate channel(key), to: CellRender

  @doc "The SMS encoding policy of a definition's `sms_encoding`; see `Relay.Templates.CellRender.policy/1`."
  @spec sms_policy(String.t() | nil) :: atom()
  def sms_policy(name), do: CellRender.policy(name)

  # CH-48
  # CH-75
  @doc "Measures a rendered SMS text for one provider in the cheapest of the allowed encodings (`GSM7`, `GSM7_TR`, `UCS2`) that carries it, after `reserved` units: `{:ok, %{encoding: name, segments: n, units: n}}`, or `:error` when none carries it; see `Relay.Templates.Sms.provider_measure/3`."
  @spec sms_measure(String.t(), [String.t()], non_neg_integer()) ::
          {:ok, %{encoding: String.t(), segments: non_neg_integer(), units: non_neg_integer()}}
          | :error
  def sms_measure(text, allowed, reserved) do
    encodings = for {name, atom} <- @sms_encodings, name in allowed, do: atom

    case Sms.provider_measure(text, encodings, reserved) do
      {:ok, m} -> {:ok, %{encoding: m.name, segments: m.segments, units: m.units}}
      :error -> :error
    end
  end

  @doc "The sensitivity class of a definition's `sensitivity`; see `Relay.Templates.CellRender.sensitivity/1`."
  @spec sensitivity(String.t() | nil) :: :public | :personal | :sensitive | nil
  defdelegate sensitivity(name), to: CellRender

  # TP-14
  @doc "The criticality declarations of an event schema; see `Relay.Templates.Variables.criticality/1`."
  @spec criticality(map()) :: %{String.t() => Context.declaration()}
  defdelegate criticality(schema), to: Variables

  # TP-38
  @doc "The schema's examples; see `Relay.Templates.Samples.examples/1`."
  @spec examples(map()) :: [Samples.sample()]
  defdelegate examples(schema), to: Samples

  # TP-38
  @doc "The automatic boundary samples of a schema; see `Relay.Templates.Samples.boundary/1`."
  @spec boundary(map()) :: [Samples.sample()]
  defdelegate boundary(schema), to: Samples

  # TP-47
  @doc "Masks a real event against its schema; see `Relay.Templates.Samples.mask/2`."
  @spec mask(term(), map()) :: term()
  defdelegate mask(event, schema), to: Samples

  # TP-47
  @doc "How many recent real events a preview samples, over how many days; see `Relay.Templates.Samples.real_event_window/0`."
  @spec real_event_window() :: %{count: pos_integer(), days: pos_integer()}
  defdelegate real_event_window(), to: Samples

  # TP-46
  # TP-54
  @doc "The lint entries of a dictionary data set: the given content, or the newest bundled version when it is `nil`; see `Relay.Templates.TermSets`."
  @spec term_entries(String.t(), map() | nil) :: [map()]
  def term_entries(name, nil), do: name |> TermSets.bundled() |> TermSets.entries()
  def term_entries(_name, content), do: TermSets.entries(content)

  # TP-49
  # TP-50
  @doc "Renders one pinned template cell for its channel on the send path; see `Relay.Templates.Render.run/1`."
  @spec render_cell(Relay.Templates.Render.input()) ::
          {:ok, Relay.Templates.Render.rendered()}
          | {:error, Relay.Templates.Render.reason(), map()}
  def render_cell(input), do: Relay.Templates.Render.run(input)

  # TP-26
  @doc "The truncation chain of a locale; see `Relay.Templates.Locale.chain/1`."
  @spec locale_chain(String.t()) :: [String.t()]
  def locale_chain(locale), do: Locale.chain(locale)
end
