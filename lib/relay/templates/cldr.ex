defmodule Relay.Templates.Cldr do
  @moduledoc """
  The single CLDR backend of Relay (TP-56): numbers, dates and times, currencies, lists and ICU messages for the supported locales. The locale data is committed under `priv/cldr/locales` and compiled in; nothing is downloaded at run time. The backend is warmed at start (TP-43).
  """

  @locales ~w(tr en de fr es it nl pt ar ru az)

  use Cldr,
    otp_app: :relay,
    locales: @locales,
    default_locale: "en",
    gettext: nil,
    generate_docs: false,
    providers: [Cldr.Number, Cldr.Calendar, Cldr.DateTime, Cldr.List, Cldr.Message]

  alias Relay.Templates.Cldr.Date, as: Dates
  alias Relay.Templates.Cldr.DateTime, as: DateTimes
  alias Relay.Templates.Cldr.Number, as: Numbers
  alias Relay.Templates.Cldr.Number.Cardinal
  alias Relay.Templates.Cldr.Time, as: Times

  @warm_number Decimal.new("1234567.891")
  @warm_money Decimal.new("1234.50")
  @warm_money_format [format: :currency, currency: "TRY"]
  @warm_at ~U[2026-09-30 23:59:59Z]
  @warm_message "{count, plural, =0 {none} zero {#} one {#} two {#} few {#} many {#} other {#}}"

  # TP-56
  @doc "The supported locales, as BCP 47 language subtags."
  @spec supported_locales() :: [String.t()]
  def supported_locales, do: @locales

  # TP-56
  @doc "The CLDR language tag used to format for a BCP 47 locale: the tag of its language subtag, when that is supported."
  @spec language_tag(String.t()) :: {:ok, Cldr.LanguageTag.t()} | :error
  def language_tag(locale) when is_binary(locale) do
    language = locale |> String.split("-", parts: 2) |> hd() |> String.downcase()

    with true <- language in @locales,
         {:ok, %Cldr.LanguageTag{} = tag} <- validate_locale(language) do
      {:ok, tag}
    else
      _ -> :error
    end
  end

  # TP-43
  @doc "Exercises the formatting paths of every supported locale once, so the first render does not pay for cold loading."
  @spec warm_up() :: :ok
  def warm_up, do: Enum.each(@locales, &warm_locale/1)

  defp warm_locale(locale) do
    {:ok, tag} = language_tag(locale)
    options = [locale: tag]
    date = DateTime.to_date(@warm_at)
    {:ok, _} = Numbers.to_string(@warm_number, options)
    {:ok, _} = Numbers.to_string(0.25, [format: :percent] ++ options)
    {:ok, _} = Numbers.to_string(@warm_money, @warm_money_format ++ options)
    {:ok, _} = DateTimes.to_string(@warm_at, [format: :medium] ++ options)
    {:ok, _} = Dates.to_string(date, [format: :medium] ++ options)
    {:ok, _} = Times.to_string(@warm_at, [format: :short] ++ options)
    _category = Cardinal.plural_rule(2, tag)
    message_options = [backend: __MODULE__] ++ options
    {:ok, _} = Cldr.Message.format(@warm_message, %{"count" => 2}, message_options)
    :ok
  end
end
