defmodule Relay.Templates.Direction do
  @moduledoc """
  Text direction of a BCP 47 locale (TP-29). A script subtag decides when present (`Arab`, `Hebr`, `Thaa`, `Syrc`, `Nkoo`, `Adlm`, `Rohg` are right to left); otherwise the language does (`ar`, `he`, `fa`, `ur`, `ps`, `sd`, `ug`, `yi`, `dv`, `ckb`, `syr`, `arc`, `nqo`).
  """

  @type t :: :ltr | :rtl

  @rtl_languages ~w(ar arc ckb dv fa he iw nqo ps sd syr ug ur yi)
  @rtl_scripts ~w(adlm arab hebr nkoo rohg syrc thaa)

  # TP-29
  @doc "The direction of a locale: `:rtl` or `:ltr`."
  @spec of(String.t() | nil) :: t()
  def of(locale) when is_binary(locale) do
    [language | rest] = locale |> String.downcase() |> String.split(["-", "_"])

    case Enum.find(rest, &Regex.match?(~r/^[a-z]{4}$/, &1)) do
      nil -> if language in @rtl_languages, do: :rtl, else: :ltr
      script -> if script in @rtl_scripts, do: :rtl, else: :ltr
    end
  end

  def of(nil), do: :ltr

  # TP-29
  @doc ~s[The value of an HTML `dir` attribute or an inbox `dir` field: `"rtl"` or `"ltr"`.]
  @spec attribute(String.t() | nil) :: String.t()
  def attribute(locale), do: Atom.to_string(of(locale))
end
