defmodule Relay.Migration.Content do
  @moduledoc """
  The canonical content form a shadow comparison digests (OP-52 (4), OP-94). Of a rendered message only the text fields `subject`, `title`, `subtitle`, `body` and `text` count, each masked in this order: a tracking pixel (an `img` element 1 pixel wide or high) is removed; a link keeps its scheme, host and path and loses its query and fragment, where signed links and tracking parameters live; an ISO 8601 timestamp becomes `<ts>`; a UUID or a Relay identifier becomes `<id>`; a run of at least 20 letters, digits, `_` or `-` with both a letter and a digit, a one-time token, becomes `<token>`; control characters are dropped and white space collapses to one space. Money and date formats are not masked. The form is the JSON object `{"channel": …, "fields": {…}}` with its members in code point order and the minimal escapes; the digest is its SHA-256 in lowercase hex. The vectors under `conformance/vectors/shadow-content` fix every rule.
  """

  @fields ~w(subject title subtitle body text)
  @pixel ~r/<img\b[^>]*\b(?:width|height)\s*=\s*["']?1(?:px)?["']?[^>]*>/i
  @link ~r{\b(https?)://([^/\s"'<>?#]+)([^\s"'<>?#]*)(?:\?[^\s"'<>#]*)?(?:#[^\s"'<>]*)?}i
  @timestamp ~r/\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?/
  @uuid ~r/\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/
  @relay_id ~r/\b[a-z]{2,3}_[0-9a-hjkmnp-tv-z]{26}\b/
  @token ~r/(?<![A-Za-z0-9_-])(?=[A-Za-z0-9_-]*[A-Za-z])(?=[A-Za-z0-9_-]*[0-9])[A-Za-z0-9_-]{20,}(?![A-Za-z0-9_-])/
  @control ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/
  @space ~r/\s+/u

  # OP-52 (4)
  # OP-94
  @doc "Masks one text field."
  @spec mask(String.t()) :: String.t()
  def mask(text) when is_binary(text) do
    text
    |> replace(@pixel, "")
    |> links()
    |> replace(@timestamp, "<ts>")
    |> replace(@uuid, "<id>")
    |> replace(@relay_id, "<id>")
    |> replace(@token, "<token>")
    |> replace(@control, "")
    |> replace(@space, " ")
    |> String.trim()
  end

  # OP-94
  @doc "The canonical form of a channel's rendered content."
  @spec canonical(String.t(), map()) :: String.t()
  def canonical(channel, content) when is_binary(channel) and is_map(content) do
    fields =
      for name <- @fields, value = content[name], is_binary(value) do
        Jason.encode!(name) <> ":" <> Jason.encode!(mask(value))
      end

    ~s({"channel":) <> Jason.encode!(channel) <> ~s(,"fields":{) <> Enum.join(fields, ",") <> "}}"
  end

  # OP-94
  @doc "The content digest of a channel's rendered content: the lowercase hex SHA-256 of its canonical form."
  @spec digest(String.t(), map()) :: String.t()
  def digest(channel, content),
    do: :sha256 |> :crypto.hash(canonical(channel, content)) |> Base.encode16(case: :lower)

  defp links(text) do
    Regex.replace(@link, text, fn _all, scheme, host, path -> link(scheme, host, path) end)
  end

  defp replace(text, pattern, replacement), do: Regex.replace(pattern, text, replacement)

  defp link(scheme, host, path),
    do: String.downcase(scheme) <> "://" <> String.downcase(host) <> path
end
