defmodule Relay.Api.Imports.Lines do
  @moduledoc """
  Pure rules of import lines (OP-96, OP-55): the NDJSON upload is split into numbered lines; a line that is too long, not valid UTF-8, not a JSON object or shows encoding damage goes to the invalid bucket with its code and never stops the import. Phone numbers are normalised to E.164 and language tags to BCP 47 (OP-55 (7)); the consent of a subscriber and channel is folded asymmetrically from all its lines (OP-55 (3)); device tokens keep only the newest line of a `(token, platform)` pair after dead tokens were dropped (OP-55 (4)); and the lines that name the same address under different external identifiers are found, never merged (OP-55 (5)).
  """

  @max_line_bytes Relay.Limits.fetch!(["import", "max_line_bytes"])
  @replacement 0xFFFD
  @lead [?Ã, ?Ä, ?Å, ?Â]
  @cp1252 ~c"‚ƒ„…†‡ˆ‰Š‹ŒŽ‘’“”•–—˜™š›œžŸ"
  @phone_noise [?\s, ?-, ?(, ?), ?., ?\t]

  @type line :: {pos_integer(), {:ok, map()} | {:invalid, String.t()}}

  # OP-96
  @doc "Splits an upload into its numbered lines, without the blank ones, each decoded or with the code of why it is invalid."
  @spec split(binary()) :: [line()]
  def split(content) when is_binary(content) do
    content
    |> :binary.split("\n", [:global])
    |> Enum.with_index(1)
    |> Enum.reject(fn {text, _number} -> blank?(text) end)
    |> Enum.map(fn {text, number} -> {number, decode(String.trim_trailing(text, "\r"))} end)
  end

  # OP-96
  @doc "The number of lines an upload holds, blank ones left out."
  @spec count(binary()) :: non_neg_integer()
  def count(content) when is_binary(content),
    do: content |> :binary.split("\n", [:global]) |> Enum.count(&(not blank?(&1)))

  defp blank?(text), do: String.valid?(text) and String.trim(text) == ""

  # OP-96
  # OP-55 (7)
  @doc "Decodes one line: `{:ok, object}`, or `{:invalid, code}` with `line_too_long`, `invalid_utf8`, `invalid_json`, `not_an_object` or `encoding_damaged`."
  @spec decode(binary()) :: {:ok, map()} | {:invalid, String.t()}
  def decode(text) when byte_size(text) > @max_line_bytes, do: {:invalid, "line_too_long"}

  def decode(text) do
    cond do
      not String.valid?(text) -> {:invalid, "invalid_utf8"}
      damaged?(text) -> {:invalid, "encoding_damaged"}
      true -> object(Jason.decode(text))
    end
  end

  defp object({:ok, %{} = map}), do: {:ok, map}
  defp object({:ok, _other}), do: {:invalid, "not_an_object"}
  defp object({:error, _error}), do: {:invalid, "invalid_json"}

  # OP-55 (7)
  @doc "Whether a valid UTF-8 text shows encoding damage: the replacement character, a C1 control character, or a Latin-1 or Windows-1252 reading of UTF-8 (`Ã§` for `ç`, `Ä±` for `ı`, `ÅŸ` for `ş`)."
  @spec damaged?(String.t()) :: boolean()
  def damaged?(text) when is_binary(text), do: damaged_chars?(String.to_charlist(text))

  defp damaged_chars?([]), do: false
  defp damaged_chars?([@replacement | _rest]), do: true
  defp damaged_chars?([char | _rest]) when char in 0x80..0x9F, do: true

  defp damaged_chars?([lead, next | _rest])
       when lead in @lead and (next in 0xA0..0xBF or next in @cp1252),
       do: true

  defp damaged_chars?([_char | rest]), do: damaged_chars?(rest)

  # OP-55 (7)
  @doc "Normalises a phone number to E.164: separators are dropped, an international `00` prefix becomes `+`, and a Turkish national number (with `country` `TR`, written with its trunk zero or as the ten digits starting with 5) gets `+90`. Any other number without a country code is `:error`; nothing is guessed."
  @spec phone(term(), term()) :: {:ok, String.t()} | :error
  def phone(text, country) when is_binary(text) do
    compact = for <<char <- text>>, char not in @phone_noise, into: "", do: <<char>>

    with candidate when is_binary(candidate) <- international(compact, country),
         {:ok, _redacted} <- Relay.Phone.new(candidate) do
      {:ok, candidate}
    else
      _other -> :error
    end
  end

  def phone(_text, _country), do: :error

  defp international("+" <> _rest = number, _country), do: number
  defp international("00" <> rest, _country), do: "+" <> rest
  defp international("0" <> rest, "TR"), do: "+90" <> rest

  defp international("5" <> _rest = number, "TR") when byte_size(number) == 10,
    do: "+90" <> number

  defp international(_number, _country), do: nil

  # OP-55 (7)
  @doc "Normalises a language tag to BCP 47 in its recommended letter case; an underscore separator (`tr_TR`) is read as a hyphen."
  @spec locale(term()) :: {:ok, String.t()} | :error
  def locale(text) when is_binary(text) do
    case Relay.Locale.new(String.replace(String.trim(text), "_", "-")) do
      {:ok, tag} -> {:ok, tag}
      {:error, _error} -> :error
    end
  end

  def locale(_text), do: :error

  # OP-55 (3)
  @doc "Folds the stated consents of one subscriber, channel and brand asymmetrically: any refusal is `:refused`; a grant is `{:granted, line}` (the last grant line) only when no line refused; anything else is `:unknown`. Whether a grant can be verified is decided afterwards; it never becomes true or false by itself."
  @spec fold_consent([{pos_integer(), String.t()}]) ::
          :refused | {:granted, pos_integer()} | :unknown
  def fold_consent(statuses) when is_list(statuses) do
    cond do
      Enum.any?(statuses, &match?({_line, "refused"}, &1)) ->
        :refused

      grant = statuses |> Enum.filter(&match?({_line, "granted"}, &1)) |> List.last() ->
        {:granted, elem(grant, 0)}

      true ->
        :unknown
    end
  end

  # OP-55 (4)
  @doc "Selects the device lines to import: dead tokens (`state` `dead`) are dropped first, then for each `(token, platform)` pair only the line with the newest `last_seen_at` stays (a line without one counts as the oldest; between equals the later line). Answers the kept lines in line order, the dead lines and the older duplicates."
  @spec select_devices([{pos_integer(), map()}]) ::
          {[{pos_integer(), map()}], [pos_integer()], [pos_integer()]}
  def select_devices(lines) do
    {dead, live} = Enum.split_with(lines, fn {_line, row} -> row["state"] == "dead" end)

    {kept, older} =
      live
      |> Enum.group_by(fn {_line, row} -> {row["token"], row["platform"]} end)
      |> Enum.reduce({[], []}, fn {_pair, group}, {kept, older} ->
        newest = Enum.max_by(group, &seen_order/1)
        others = for {line, _row} = entry <- group, entry != newest, do: line
        {[newest | kept], older ++ others}
      end)

    {Enum.sort_by(kept, &elem(&1, 0)), Enum.map(dead, &elem(&1, 0)), Enum.sort(older)}
  end

  defp seen_order({line, row}) do
    case parse_time(row["last_seen_at"]) do
      {:ok, at} -> {1, DateTime.to_unix(at, :microsecond), line}
      :error -> {0, 0, line}
    end
  end

  # OP-96
  @doc "Parses an RFC 3339 time; `:error` for anything else."
  @spec parse_time(term()) :: {:ok, DateTime.t()} | :error
  def parse_time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _reason} -> :error
    end
  end

  def parse_time(_text), do: :error

  # OP-55 (5)
  @doc "The groups of lines that give the same address of `field` under different external identifiers; each group is reported and nothing is merged."
  @spec conflicts([{pos_integer(), String.t(), String.t() | nil}]) :: [[pos_integer()]]
  def conflicts(entries) do
    entries
    |> Enum.reject(fn {_line, _external_id, address} -> is_nil(address) end)
    |> Enum.group_by(fn {_line, _external_id, address} -> address end)
    |> Enum.map(fn {_address, group} -> group end)
    |> Enum.filter(fn group ->
      ids = Enum.map(group, fn {_line, external_id, _address} -> external_id end)
      length(Enum.uniq(ids)) > 1
    end)
    |> Enum.map(fn group -> group |> Enum.map(&elem(&1, 0)) |> Enum.sort() end)
    |> Enum.sort()
  end
end
