defmodule Relay.Templates do
  @moduledoc """
  Templates, localisation and rendering. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Templates.Cldr
  alias Relay.Templates.Context
  alias Relay.Templates.Engine
  alias Relay.Templates.Locale
  alias Relay.Templates.Sandbox
  alias Relay.Templates.Variables

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

  # TP-49
  # TP-50
  @doc "Renders one pinned template cell for its channel on the send path; see `Relay.Templates.Render.run/1`."
  @spec render_cell(Relay.Templates.Render.input()) ::
          {:ok, Relay.Templates.Render.rendered()}
          | {:error, Relay.Templates.Render.reason(), map()}
  def render_cell(input), do: Relay.Templates.Render.run(input)
end
