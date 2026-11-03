defmodule Relay.Templates.Channel.Email do
  @moduledoc """
  E-mail output (TP-22, TP-29). A variant has four fields with string keys: `"subject"`, `"preheader"`, `"html"` and `"text"`; the plain text body is mandatory and separate.

  Line breaks are removed from the subject and the preheader (each run becomes one space), a subject over 78 characters after render is a warning (TP-57) and a non-ASCII subject is encoded as RFC 2047 `B` encoded-words. The rendered HTML is measured after variable injection: over 70 000 bytes is a warning, over 90 000 bytes a rejection. A missing `color-scheme` meta tag is a warning, AMP for Email is refused, and an RTL locale gets `dir="rtl"` on the `html` element. Every content change is recorded (INV-1).
  """

  alias Relay.Templates.Direction
  alias Relay.Templates.Finding
  alias Relay.Templates.Sanitizer

  @type output :: %{
          subject: String.t(),
          subject_header: String.t(),
          preheader: String.t(),
          html: String.t(),
          text: String.t(),
          html_bytes: non_neg_integer(),
          dir: String.t()
        }
  @type ok :: %{output: output(), changes: [Sanitizer.change()], findings: [Finding.t()]}

  @warn_bytes 70_000
  @max_bytes 90_000
  @word_bytes 45
  @subject_characters 78

  @html_tag ~r/<html\b[^>]*>/i
  @dir_attribute ~r/\sdir\s*=/i
  @color_scheme ~r/<meta\b[^>]*\bname\s*=\s*["']?color-scheme\b/i
  @amp ~r/<html\b[^>]*(\x{26A1}4email|\bamp4email\b)/iu
  @rtl_dir ~r/<html\b[^>]*\sdir\s*=\s*["']?rtl\b/i

  # TP-22
  @doc "The HTML size thresholds in bytes: `{warning, rejection}`."
  @spec html_limits() :: {pos_integer(), pos_integer()}
  def html_limits, do: {@warn_bytes, @max_bytes}

  # TP-22
  # TP-29
  @doc "Cleans and measures the rendered fields; `opts` takes `:locale`. Hard findings make it an error; warnings travel with the output."
  @spec render(map(), keyword()) :: {:ok, ok()} | {:error, [Finding.t()]}
  def render(fields, opts \\ []) do
    locale = Keyword.get(opts, :locale)
    {subject, subject_changes} = header_field(fields, "subject")
    {preheader, preheader_changes} = header_field(fields, "preheader")
    {text, text_changes} = Sanitizer.utf8(string(fields, "text"), "text")
    {html, html_changes} = clean_html(string(fields, "html"), locale)

    output = %{
      subject: subject,
      subject_header: encode_subject(subject),
      preheader: preheader,
      html: html,
      text: text,
      html_bytes: byte_size(html),
      dir: Direction.attribute(locale)
    }

    changes = subject_changes ++ preheader_changes ++ html_changes ++ text_changes
    {hard, warnings} = output |> findings(locale) |> Finding.split()

    if hard == [],
      do: {:ok, %{output: output, changes: changes, findings: warnings}},
      else: {:error, hard ++ warnings}
  end

  # TP-22
  # TP-32
  @doc "Publish gate check of the worst-case rendered fields: every finding of `render/2`."
  @spec publish_findings(map(), keyword()) :: [Finding.t()]
  def publish_findings(worst_case, opts \\ []) do
    case render(worst_case, opts) do
      {:ok, %{findings: findings}} -> findings
      {:error, findings} -> findings
    end
  end

  # TP-22
  @doc "The subject as a header value: unchanged when it is printable ASCII, otherwise UTF-8 `B` encoded-words of at most 75 characters, folded with CRLF and a space, never splitting a character."
  @spec encode_subject(String.t()) :: String.t()
  def encode_subject(subject) do
    if printable_ascii?(subject) do
      subject
    else
      subject
      |> String.to_charlist()
      |> Enum.chunk_while({[], 0}, &chunk/2, &chunk_end/1)
      |> Enum.map_join("\r\n ", &("=?UTF-8?B?" <> Base.encode64(&1) <> "?="))
    end
  end

  # TP-29
  @doc "Adds `dir=\"rtl\"` to the `html` element for an RTL locale when the element has no `dir`; the addition is recorded."
  @spec put_dir(String.t(), String.t() | nil) :: Sanitizer.result()
  def put_dir(html, locale) do
    with :rtl <- Direction.of(locale),
         [tag] <- Regex.run(@html_tag, html),
         false <- Regex.match?(@dir_attribute, tag) do
      rest = binary_part(tag, 5, byte_size(tag) - 5)
      updated = String.replace(html, tag, ~s(<html dir="rtl") <> rest, global: false)
      {updated, [Sanitizer.change(:rtl_dir, :added, 1, field: "html")]}
    else
      _other -> {html, []}
    end
  end

  defp header_field(fields, key) do
    {value, changes} = Sanitizer.utf8(string(fields, key), key)

    case length(Regex.scan(~r/[\r\n]/, value)) do
      0 ->
        {value, changes}

      count ->
        change = Sanitizer.change(:line_break, :replaced, count, field: key)
        {String.replace(value, ~r/[\r\n]+/, " "), changes ++ [change]}
    end
  end

  defp clean_html(html, locale) do
    {html, changes} = Sanitizer.utf8(html, "html")
    {html, more} = put_dir(html, locale)
    {html, changes ++ more}
  end

  defp string(fields, key) do
    case Map.get(fields, key) do
      value when is_binary(value) -> value
      _absent -> ""
    end
  end

  defp printable_ascii?(text), do: Regex.match?(~r/\A[\x20-\x7E]*\z/, text)

  defp chunk(codepoint, {acc, size}) do
    char = <<codepoint::utf8>>

    if size + byte_size(char) > @word_bytes,
      do: {:cont, flush(acc), {[char], byte_size(char)}},
      else: {:cont, {[char | acc], size + byte_size(char)}}
  end

  defp chunk_end({[], _size}), do: {:cont, {[], 0}}
  defp chunk_end({acc, _size}), do: {:cont, flush(acc), {[], 0}}

  defp flush(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp findings(output, locale) do
    fields = [channel: :email, locale: locale]

    for {check, level, pointer, detail} <- checks(output, locale),
        do: Finding.new(check, level, [pointer: pointer, detail: detail] ++ fields)
  end

  defp checks(%{html: html} = output, locale) do
    Enum.filter(
      [
        String.trim(output.text) == "" && {:email_plain_text, :hard, "/text", %{}},
        subject_length(output.subject),
        html_size(output.html_bytes),
        Regex.match?(@amp, html) && {:email_amp, :hard, "/html", %{}},
        !Regex.match?(@color_scheme, html) && {:email_color_scheme, :warning, "/html", %{}},
        rtl_missing?(html, locale) && {:email_dir, :warning, "/html", %{}}
      ],
      &is_tuple/1
    )
  end

  # TP-57
  defp subject_length(subject) do
    case String.length(subject) do
      length when length > @subject_characters ->
        detail = %{characters: length, limit: @subject_characters}
        {:email_subject_length, :warning, "/subject", detail}

      _length ->
        false
    end
  end

  defp html_size(bytes) do
    detail = %{bytes: bytes, warning: @warn_bytes, limit: @max_bytes}

    cond do
      bytes > @max_bytes -> {:email_html_size, :hard, "/html", detail}
      bytes > @warn_bytes -> {:email_html_size, :warning, "/html", detail}
      true -> false
    end
  end

  defp rtl_missing?(html, locale),
    do: Direction.of(locale) == :rtl and not Regex.match?(@rtl_dir, html)
end
