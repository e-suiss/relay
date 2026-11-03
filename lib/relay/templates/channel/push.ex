defmodule Relay.Templates.Channel.Push do
  @moduledoc """
  Push output (TP-20, TP-21). Push is rendered on the server and carries plain `title`, `body` and optional `subtitle`. A `sensitive` template carries `lock_screen_body`, a neutral text that is the only body in the payload, and `in_app_body`, the full content the app fetches when it opens; the lock screen never shows the full content.

  The payload is built only with the JSON encoder and measured in bytes; over 4096 bytes (APNs) it is rejected, never cut. Invalid UTF-8 is removed first and recorded (INV-1). A text field may hold at most 1024 characters, counted in UTF-16 code units as Android counts them; at the publish gate the worst-case variant over that limit is a hard finding.

  Fields are maps with string keys: `"title"`, `"subtitle"`, `"body"` for `public` and `personal`; `"title"`, `"subtitle"`, `"lock_screen_body"`, `"in_app_body"` for `sensitive`.
  """

  alias Relay.Templates.Finding
  alias Relay.Templates.Sanitizer

  @type sensitivity :: :public | :personal | :sensitive
  @type output :: %{
          title: String.t(),
          subtitle: String.t() | nil,
          body: String.t(),
          in_app_body: String.t() | nil,
          payload: String.t(),
          bytes: non_neg_integer()
        }
  @type result ::
          {:ok, %{output: output(), changes: [Sanitizer.change()]}} | {:error, [Finding.t()]}

  @sensitivities [:public, :personal, :sensitive]
  @max_bytes 4096
  @max_characters 1024

  # TP-20
  @doc "The APNs payload limit in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  # TP-20
  @doc "The text field limit in UTF-16 code units (Android `MAX_CHARSEQUENCE_LENGTH`)."
  @spec max_characters() :: pos_integer()
  def max_characters, do: @max_characters

  # TP-20
  # TP-21
  @doc "Cleans the rendered fields, builds the payload with the JSON encoder and measures it; `opts` takes `:locale` for findings. A payload over 4096 bytes, a field over 1024 characters or a missing body is an error."
  @spec render(map(), sensitivity(), keyword()) :: result()
  def render(fields, sensitivity, opts \\ []) when sensitivity in @sensitivities do
    {clean, changes} = clean(fields, sensitivity)
    payload = Jason.encode!(payload(clean))
    output = Map.merge(clean, %{payload: payload, bytes: byte_size(payload)})

    case findings(output, sensitivity, Keyword.get(opts, :locale)) do
      [] -> {:ok, %{output: output, changes: changes}}
      findings -> {:error, findings}
    end
  end

  # TP-20
  # TP-32
  @doc "Publish gate check of the worst-case rendered fields: the same limits as `render/3`, as hard findings."
  @spec publish_findings(map(), sensitivity(), keyword()) :: [Finding.t()]
  def publish_findings(worst_case, sensitivity, opts \\ []) do
    case render(worst_case, sensitivity, opts) do
      {:ok, _result} -> []
      {:error, findings} -> findings
    end
  end

  # TP-20
  @doc "The length of a text in UTF-16 code units."
  @spec utf16_length(String.t()) :: non_neg_integer()
  def utf16_length(text), do: text |> :unicode.characters_to_binary(:utf8, :utf16) |> div2()

  defp div2(binary) when is_binary(binary), do: div(byte_size(binary), 2)

  defp clean(fields, sensitivity) do
    {values, changes} =
      Enum.map_reduce(keys(sensitivity), [], fn key, acc ->
        {value, more} = field(fields, key)
        {{key, value}, acc ++ more}
      end)

    values = Map.new(values)

    clean = %{
      title: values["title"] || "",
      subtitle: values["subtitle"],
      body: values[body_key(sensitivity)] || "",
      in_app_body: values["in_app_body"]
    }

    {clean, changes}
  end

  defp keys(:sensitive), do: ["title", "subtitle", "lock_screen_body", "in_app_body"]
  defp keys(_sensitivity), do: ["title", "subtitle", "body"]

  defp body_key(:sensitive), do: "lock_screen_body"
  defp body_key(_sensitivity), do: "body"

  defp field(fields, key) do
    case Map.get(fields, key) do
      value when is_binary(value) -> Sanitizer.utf8(value, key)
      _absent -> {nil, []}
    end
  end

  defp payload(clean) do
    alert =
      %{"title" => clean.title, "subtitle" => clean.subtitle, "body" => clean.body}
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    %{"aps" => %{"alert" => alert}}
  end

  defp findings(output, sensitivity, locale) do
    fields = [channel: :push, locale: locale]

    missing(output, sensitivity, fields) ++
      too_long(output, sensitivity, fields) ++ too_large(output, fields)
  end

  defp missing(%{body: ""}, sensitivity, fields) do
    pointer = "/" <> body_key(sensitivity)
    [Finding.new(:push_body_missing, :hard, [pointer: pointer] ++ fields)]
  end

  defp missing(%{in_app_body: nil}, :sensitive, fields),
    do: [Finding.new(:push_body_missing, :hard, [pointer: "/in_app_body"] ++ fields)]

  defp missing(_output, _sensitivity, _fields), do: []

  defp too_long(output, sensitivity, fields) do
    [title: "title", subtitle: "subtitle", body: body_key(sensitivity)]
    |> Enum.flat_map(fn {key, name} -> too_long_field(Map.fetch!(output, key), name, fields) end)
  end

  defp too_long_field(value, name, fields) when is_binary(value) do
    case utf16_length(value) do
      length when length > @max_characters ->
        detail = %{characters: length, limit: @max_characters}
        [Finding.new(:push_characters, :hard, [pointer: "/" <> name, detail: detail] ++ fields)]

      _length ->
        []
    end
  end

  defp too_long_field(_value, _name, _fields), do: []

  defp too_large(%{bytes: bytes}, fields) when bytes > @max_bytes do
    detail = %{bytes: bytes, limit: @max_bytes}
    [Finding.new(:push_payload_size, :hard, [pointer: "", detail: detail] ++ fields)]
  end

  defp too_large(_output, _fields), do: []
end
