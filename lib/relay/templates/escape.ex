defmodule Relay.Templates.Escape do
  @moduledoc """
  Escaping of injected values by channel type (TP-24) and bidirectional isolation of injected values in right-to-left locales (TP-29).

  Modes:

    * `:html` — HTML entity escaping of `&`, `<`, `>`, `"` and `'` (email HTML).
    * `:text` — line breaks (CR, LF, NEL, U+2028, U+2029) become a space (email subject and preheader, plain text, SMS, chat).
    * `:json` — values are left as they are; the channel payload is built by the JSON encoder, never by string concatenation (push, webhook).
    * `:structured` — values are left as they are and travel in structured fields, never as HTML (inbox).
  """

  @type mode :: :html | :text | :json | :structured

  @modes [:html, :text, :json, :structured]
  @line_breaks ["\r\n", "\r", "\n", "\u0085", " ", " "]
  @entities %{"&amp;" => "&", "&lt;" => "<", "&gt;" => ">", "&quot;" => "\"", "&#39;" => "'"}
  @entity ~r/&(?:amp|lt|gt|quot|#39);/
  @first_strong_isolate "⁨"
  @pop_directional_isolate "⁩"

  @doc "The escaping modes."
  @spec modes() :: [mode()]
  def modes, do: @modes

  # TP-24
  @doc "Escapes a string for `mode`."
  @spec escape(String.t(), mode()) :: String.t()
  def escape(string, :html) when is_binary(string),
    do: for(<<byte <- string>>, into: "", do: html(byte))

  def escape(string, :text) when is_binary(string), do: String.replace(string, @line_breaks, " ")
  def escape(string, mode) when is_binary(string) and mode in [:json, :structured], do: string

  # TP-24
  @doc "Reverses `escape/2` for a string escaped by it; only `:html` changes anything."
  @spec unescape(String.t(), mode()) :: String.t()
  def unescape(string, :html) when is_binary(string),
    do: Regex.replace(@entity, string, fn entity -> Map.fetch!(@entities, entity) end)

  def unescape(string, mode) when is_binary(string) and mode in [:text, :json, :structured],
    do: string

  # TP-24
  @doc "Escapes every string leaf of a JSON-like value for `mode`; map keys are left as they are."
  @spec value(term(), mode()) :: term()
  def value(string, mode) when is_binary(string), do: escape(string, mode)
  def value(list, mode) when is_list(list), do: Enum.map(list, &value(&1, mode))

  def value(map, mode) when is_map(map),
    do: Map.new(map, fn {key, item} -> {key, value(item, mode)} end)

  def value(other, _mode), do: other

  # TP-29
  @doc "Wraps a non-empty string in U+2068 FIRST STRONG ISOLATE and U+2069 POP DIRECTIONAL ISOLATE."
  @spec isolate(String.t()) :: String.t()
  def isolate(""), do: ""

  def isolate(string) when is_binary(string),
    do: @first_strong_isolate <> string <> @pop_directional_isolate

  defp html(?&), do: "&amp;"
  defp html(?<), do: "&lt;"
  defp html(?>), do: "&gt;"
  defp html(?"), do: "&quot;"
  defp html(?'), do: "&#39;"
  defp html(byte), do: <<byte>>
end
