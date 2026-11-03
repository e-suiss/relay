defmodule Relay.Templates.Sms.Encoding do
  @moduledoc """
  SMS character encodings (TP-18, CH-48): `:gsm7` is the GSM 03.38 default alphabet with its extension table, `:gsm7_tr` the default alphabet with the Turkish single shift table of 3GPP TS 23.038 Annex A.2.1, and `:ucs2` sixteen-bit code units.

  A character costs units: in `:gsm7` one septet for the default alphabet and two for the extension table (`^ { } \\ [ ] ~ | €`); in `:gsm7_tr` additionally two for `ç ğ Ğ ı İ ş Ş` and, conservatively, two for `Ç` (TP-18); in `:ucs2` one unit per code point of the Basic Multilingual Plane and two (a surrogate pair) above it. A character outside a table makes the text unrepresentable in that encoding.
  """

  @type t :: :gsm7 | :gsm7_tr | :ucs2
  @type policy :: :transliterate | :turkish_shift | :ucs2
  @type unsupported :: %{codepoint: non_neg_integer(), count: pos_integer()}

  @basic ~c"@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà"
  @extension ~c"^{}\\[~]|€"
  @turkish ~c"ĞİŞçğış"

  @gsm7 Map.merge(Map.new(@basic, &{&1, 1}), Map.new(@extension, &{&1, 2}))
  @gsm7_tr Map.merge(@gsm7, Map.new([?Ç | @turkish], &{&1, 2}))

  @names %{gsm7: "GSM7", gsm7_tr: "GSM7_TR", ucs2: "UCS2"}

  # CH-48
  @doc "The encoding name given to the provider: `GSM7`, `GSM7_TR` or `UCS2`."
  @spec name(t()) :: String.t()
  def name(encoding), do: Map.fetch!(@names, encoding)

  # TP-18
  @doc "The encodings a policy may choose from, cheapest first: `:ucs2` never uses the Turkish single shift table."
  @spec candidates(policy()) :: [t()]
  def candidates(:ucs2), do: [:gsm7, :ucs2]

  def candidates(policy) when policy in [:transliterate, :turkish_shift],
    do: [:gsm7, :gsm7_tr, :ucs2]

  # TP-18
  # CH-48
  @doc "The units one code point costs in `encoding`, or `nil` when the encoding cannot carry it."
  @spec cost(non_neg_integer(), t()) :: 1 | 2 | nil
  def cost(codepoint, :gsm7), do: Map.get(@gsm7, codepoint)
  def cost(codepoint, :gsm7_tr), do: Map.get(@gsm7_tr, codepoint)
  def cost(codepoint, :ucs2) when codepoint > 0xFFFF, do: 2
  def cost(_codepoint, :ucs2), do: 1

  # TP-18
  @doc "The unit cost of every code point of `text` in order, or `:error` when `encoding` cannot carry one of them."
  @spec units(String.t(), t()) :: {:ok, [1 | 2]} | :error
  def units(text, encoding) do
    text
    |> String.to_charlist()
    |> Enum.reduce_while([], fn codepoint, acc ->
      case cost(codepoint, encoding) do
        nil -> {:halt, :error}
        unit -> {:cont, [unit | acc]}
      end
    end)
    |> case do
      :error -> :error
      units -> {:ok, Enum.reverse(units)}
    end
  end

  # TP-18
  @doc "True when `encoding` can carry every code point of `text`."
  @spec fits?(String.t(), t()) :: boolean()
  def fits?(text, encoding), do: units(text, encoding) != :error

  # TP-18
  @doc "The cheapest encoding the policy allows for `text`."
  @spec choose(String.t(), policy()) :: t()
  def choose(text, policy), do: Enum.find(candidates(policy), :ucs2, &fits?(text, &1))

  # CH-48
  @doc "The code points of `text` that `encoding` cannot carry, with their counts, in order of first appearance."
  @spec unsupported(String.t(), t()) :: [unsupported()]
  def unsupported(text, encoding) do
    text
    |> String.to_charlist()
    |> Enum.reject(&cost(&1, encoding))
    |> Enum.frequencies()
    |> Enum.map(fn {codepoint, count} -> %{codepoint: codepoint, count: count} end)
    |> order_by_appearance(text)
  end

  defp order_by_appearance(entries, text) do
    first = text |> String.to_charlist() |> Enum.with_index() |> Enum.reverse() |> Map.new()
    Enum.sort_by(entries, &Map.fetch!(first, &1.codepoint))
  end
end
