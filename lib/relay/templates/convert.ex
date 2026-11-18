defmodule Relay.Templates.Convert do
  @moduledoc """
  Template conversion for imports (OP-96, OP-55 (9)): a Liquid or Handlebars source is converted to Relay's Liquid subset by a syntax tree converter (`Relay.Templates.Convert.Liquid`, `Relay.Templates.Convert.Handlebars`), and the output is parsed again by the template engine (`Relay.Templates.Engine`), so an output that the engine refuses is never offered. Each template gets one status: `AUTO_OK` when it converted without a known difference, `NEEDS_REVIEW` when it converted with differences its findings name, `CANNOT` when something has no equivalent; a `CANNOT` template has no output. Informational findings (an `escape` filter or a `log` helper dropped) do not change the status.
  """

  alias Relay.Templates.Convert.Expr
  alias Relay.Templates.Convert.Handlebars
  alias Relay.Templates.Convert.Liquid
  alias Relay.Templates.Engine

  @type language :: :liquid | :handlebars
  @type finding :: %{code: String.t(), line: pos_integer() | nil, detail: String.t()}
  @type result :: %{
          status: String.t(),
          output: String.t() | nil,
          findings: [finding()],
          aliases: [String.t()]
        }

  @detail_max 512

  # OP-96
  # OP-55 (9)
  @doc "Converts `source` written in `language` with the alias table `aliases` (old variable path to Relay path) and answers its status, its output (`nil` for `CANNOT`), its findings and the aliases it used."
  @spec convert(language(), String.t(), %{String.t() => String.t()}) :: result()
  def convert(language, source, aliases \\ %{})
      when language in [:liquid, :handlebars] and is_binary(source) and is_map(aliases) do
    if String.valid?(source) do
      converted(language, source, aliases)
    else
      finish([{:cannot, "invalid_utf8", nil, "the source is not valid UTF-8"}], nil, [])
    end
  end

  defp converted(language, source, aliases) do
    result =
      case language do
        :liquid -> Liquid.convert(source, aliases)
        :handlebars -> Handlebars.convert(source, aliases)
      end

    output = Expr.render(result.tokens)
    finish(result.findings ++ engine(output, result.raw), output, result.aliases)
  end

  defp engine(output, raw) do
    case Engine.parse(output, allow_raw: raw) do
      {:ok, _template} -> []
      {:error, findings} -> Enum.map(findings, &{:cannot, &1.code, &1.line, &1.detail})
    end
  end

  defp finish(findings, output, aliases) do
    status = status(findings)

    %{
      status: status,
      output: if(status == "CANNOT", do: nil, else: output),
      findings: Enum.map(findings, &view/1),
      aliases: aliases
    }
  end

  # OP-96
  @doc "The status of a list of findings: any `:cannot` is `CANNOT`, else any `:review` is `NEEDS_REVIEW`, else `AUTO_OK`."
  @spec status([{:info | :review | :cannot, String.t(), pos_integer() | nil, String.t()}]) ::
          String.t()
  def status(findings) do
    severities = MapSet.new(findings, &elem(&1, 0))

    cond do
      MapSet.member?(severities, :cannot) -> "CANNOT"
      MapSet.member?(severities, :review) -> "NEEDS_REVIEW"
      true -> "AUTO_OK"
    end
  end

  defp view({_severity, code, line, detail}),
    do: %{code: code, line: line, detail: String.slice(detail, 0, @detail_max)}
end
