defmodule Relay.Templates.Lint.LegalFooter do
  @moduledoc """
  The mandatory legal footer check of the publish gate (TP-33, TP-55). Every channel variant of a commercial (`marketing`) template must use the `legal_footer` render helper, and the brand fields the helper is built from must be filled for the tenant's country; anything missing is a hard finding.

  A variant is `%{channel: atom, locale: String.t(), helpers: [String.t()], opt_out: String.t() | nil}`: `helpers` are the render helpers the parsed template uses and `opt_out` is the resolved opt-out instruction of that channel (the SMS opt-out short code text, the e-mail `unsubscribe_url`). Brand fields are a map with string keys and without the `brand.` prefix.

  Required per country: `TR` needs `legal_name`, `mersis` or `contact` and the opt-out instruction, while the helper itself appends the commercial message mark from Relay's system text (TP-60); `US` needs `postal_address`. Other countries need the helper only.

  A commercial voice variant names its sender by the trade name, not by an SMS header (CH-56): in every country it needs the brand's `legal_name`, the `voice_trade_name` hard finding otherwise.
  """

  alias Relay.Templates.Finding

  @type variant :: %{
          required(:channel) => atom(),
          required(:locale) => String.t() | nil,
          required(:helpers) => [String.t()],
          optional(:opt_out) => String.t() | nil
        }

  @helper "legal_footer"

  # TP-33
  # TP-55
  @doc "Publish gate check. Options: `:message_class` (only `\"marketing\"` is checked) and `:country` (ISO 3166-1 alpha-2)."
  @spec check([variant()], map(), keyword()) :: [Finding.t()]
  def check(variants, brand, opts \\ []) do
    if Keyword.get(opts, :message_class) == "marketing" do
      country = opts |> Keyword.get(:country, "") |> to_string() |> String.upcase()
      Enum.flat_map(variants, &variant(&1, brand, country))
    else
      []
    end
  end

  # TP-55
  @doc "The brand and variant fields a country requires that are blank, in a fixed order."
  @spec missing(map(), map(), String.t()) :: [String.t()]
  def missing(brand, variant, "TR") do
    [
      blank?(brand["legal_name"]) && "legal_name",
      (blank?(brand["mersis"]) and blank?(brand["contact"])) && "mersis_or_contact",
      blank?(Map.get(variant, :opt_out)) && "opt_out"
    ]
    |> Enum.filter(&is_binary/1)
  end

  def missing(brand, _variant, "US") do
    if blank?(brand["postal_address"]), do: ["postal_address"], else: []
  end

  def missing(_brand, _variant, _country), do: []

  defp variant(variant, brand, country) do
    fields = [channel: variant.channel, locale: variant.locale]

    helper =
      if @helper in variant.helpers,
        do: [],
        else: [Finding.new(:legal_footer_missing, :hard, fields)]

    helper = helper ++ trade_name(variant, brand, fields)

    case missing(brand, variant, country) do
      [] ->
        helper

      absent ->
        detail = %{missing: absent, country: country}
        helper ++ [Finding.new(:legal_footer_fields, :hard, [detail: detail] ++ fields)]
    end
  end

  # CH-56
  defp trade_name(%{channel: :voice}, brand, fields) do
    if blank?(brand["legal_name"]),
      do: [Finding.new(:voice_trade_name, :hard, fields)],
      else: []
  end

  defp trade_name(_variant, _brand, _fields), do: []

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true
end
