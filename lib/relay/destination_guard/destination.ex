defmodule Relay.DestinationGuard.Destination do
  @moduledoc """
  The pure part of the protections of `security` SMS destinations (CH-54, E-33): what a phone number's country and number block are, which countries a tenant may send to, and when a count is an SMS pumping anomaly.

    * Country. The country of an E.164 number is the country of its calling code (`Relay.Phone.country/1`). The two shared codes are split by their leading digits: under `+1` the area codes of the Caribbean and Pacific members of the numbering plan name their own country and every other area code counts as `US`, Canada included, since the two are not told apart without a numbering plan data set; under `+7` a number starting with `6` or `7` is `KZ` and every other `RU`. A number whose code names no country has none and is never on an allow-list.
    * Number block. The number without its last `block_digits` digits, at least its first two digits: with three digits a block of a thousand numbers.
    * Allow-list. The countries of the tenant's region (`TR`; the member states of the European Economic Area; `US`) and the countries the tenant added (`sms.security.allowed_countries`).
    * Anomaly. Sends counted to a destination in the detection window are an anomaly when they reach `min_volume` and `multiplier` times the share of that window in the count of the baseline window, the tenant's own baseline for that destination. The detection reads nothing about verification outcomes: the sender verifies the codes, not Relay (INV-22).
  """

  @nanp %{
    "242" => "BS",
    "246" => "BB",
    "264" => "AI",
    "268" => "AG",
    "284" => "VG",
    "340" => "VI",
    "345" => "KY",
    "441" => "BM",
    "473" => "GD",
    "649" => "TC",
    "658" => "JM",
    "664" => "MS",
    "670" => "MP",
    "671" => "GU",
    "684" => "AS",
    "721" => "SX",
    "758" => "LC",
    "767" => "DM",
    "784" => "VC",
    "787" => "PR",
    "809" => "DO",
    "829" => "DO",
    "849" => "DO",
    "868" => "TT",
    "869" => "KN",
    "876" => "JM",
    "939" => "PR"
  }

  @eea ~w(AT BE BG CY CZ DE DK EE ES FI FR GR HR HU IE IS IT LI LT LU LV MT NL NO PL PT RO SE SI
          SK)

  @e164 ~r/\A\+[1-9][0-9]{6,14}\z/

  @type detection :: %{
          required(:min_volume) => pos_integer(),
          required(:multiplier) => pos_integer(),
          required(:window_s) => pos_integer(),
          required(:baseline_window_s) => pos_integer()
        }

  @doc "Returns true when `number` is an E.164 number the protections can place: `+`, a calling code and at least seven digits in all."
  @spec number?(term()) :: boolean()
  def number?(number), do: is_binary(number) and Regex.match?(@e164, number)

  # CH-54
  @doc "The country of an E.164 number as an ISO 3166-1 alpha-2 code, or `nil` when its calling code names none."
  @spec country(String.t()) :: String.t() | nil
  def country("+1" <> rest), do: Map.get(@nanp, String.slice(rest, 0, 3), "US")
  def country(<<"+7", first, _rest::binary>>) when first in [?6, ?7], do: "KZ"
  def country("+7" <> _rest), do: "RU"
  def country(number) when is_binary(number), do: Relay.Phone.country(number)

  # CH-54
  @doc "The number block of an E.164 number: the number without its last `digits` digits, never shorter than `+` and two digits."
  @spec block(String.t(), pos_integer()) :: String.t()
  def block("+" <> all, digits) when is_integer(digits) and digits > 0 do
    keep = max(String.length(all) - digits, 2)
    "+" <> String.slice(all, 0, keep)
  end

  # CH-54
  @doc "The countries of a tenant's region, the default of its allow-list."
  @spec region_countries(Relay.Region.t()) :: [String.t(), ...]
  def region_countries(:tr), do: ["TR"]
  def region_countries(:us), do: ["US"]
  def region_countries(:eu), do: @eea

  # CH-54
  @doc "Returns true when `country` is a country of the tenant's region or one the tenant added; a number without a country is never allowed."
  @spec allowed?(String.t() | nil, Relay.Region.t(), [String.t()]) :: boolean()
  def allowed?(nil, _region, _added), do: false

  def allowed?(country, region, added) when is_binary(country) and is_list(added),
    do: country in region_countries(region) or country in added

  # CH-54
  @doc "The count in the detection window at which a destination with `baseline` sends in the baseline window is an anomaly: `multiplier` times the baseline's share of the window, and never under `min_volume`."
  @spec threshold(non_neg_integer(), detection()) :: pos_integer()
  def threshold(baseline, %{} = d) when is_integer(baseline) and baseline >= 0 do
    scaled = baseline * d.multiplier * d.window_s
    expected = div(scaled + d.baseline_window_s - 1, d.baseline_window_s)
    max(d.min_volume, expected)
  end

  # CH-54
  @doc "Returns true when `current` sends in the detection window are an anomaly against `baseline`."
  @spec anomaly?(non_neg_integer(), non_neg_integer(), detection()) :: boolean()
  def anomaly?(current, baseline, detection), do: current >= threshold(baseline, detection)
end
