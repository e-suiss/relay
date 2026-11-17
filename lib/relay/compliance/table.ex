defmodule Relay.Compliance.Table do
  @moduledoc """
  The compliance table as data (PC-40, MD-17): the content of a `compliance_table` version and the pure rules that read it. A country row gives, for a country, channels, message classes and legal recipient types, the consent kinds that are enough and the row's obligations: the footer fields, the legal send window and the scope of a revocation. A platform row gives the rule of an app store or a messaging platform, independent of the country (PC-54).

  A country is matched by the rows that name it or a region it belongs to. A country with rows of its own is governed by them alone: a channel and class none of them names has no condition, because Relay adds no condition the law does not ask for (PC-43). A country without any row takes the `*` rows, where marketing needs explicit opt-in (PC-41). Exceptions are rows: the merchant row, the soft opt-in row and the legitimate interest row (PC-42).

  Consent kinds are ordered `none`, `legitimate_interest`, `soft_opt_in`, `explicit_opt_in`. A row needs the weakest kind it lists and accepts every kind at or above it. A refusal of the tenant (`Relay.Compliance.Settings`) removes a kind from a row, so the row then needs the next kind it still lists, or explicit opt-in when none is left; a row that needs no consent is not changed by a refusal (INV-17).

  The newest version bundled with the release is compiled in as the fallback of an installation without an active version.
  """

  dir = Path.join([__DIR__, "..", "..", "..", "priv", "datasets", "compliance_table"])
  paths = Path.wildcard(Path.join(dir, "v*.json"))
  for path <- paths, do: @external_resource(path)

  {number, newest} =
    paths
    |> Enum.map(fn path ->
      {path |> Path.basename(".json") |> String.trim_leading("v") |> String.to_integer(), path}
    end)
    |> Enum.max()

  @bundled newest |> File.read!() |> Jason.decode!()
  @bundled_no number

  @strength %{
    "none" => 0,
    "legitimate_interest" => 1,
    "soft_opt_in" => 2,
    "explicit_opt_in" => 3
  }
  @kinds %{0 => "none", 1 => "legitimate_interest", 2 => "soft_opt_in", 3 => "explicit_opt_in"}
  @explicit 3

  @type content :: %{required(String.t()) => term()}
  @type row :: %{required(String.t()) => term()}
  @type query :: %{
          required(:channel) => String.t(),
          required(:class) => String.t(),
          required(:recipient_type) => String.t(),
          required(:platform) => String.t() | nil,
          required(:countries) => [String.t()],
          required(:fallback) => String.t()
        }
  @type window :: %{row: String.t(), from: Time.t(), to: Time.t(), zones: [String.t()]}
  @type resolution :: %{
          required: String.t(),
          accepted: [String.t()],
          country: String.t(),
          row: String.t() | nil,
          platform_row: String.t() | nil,
          default: :locked_off | :tenant,
          legal_windows: [window()],
          revocation_channels: [String.t()]
        }

  # PC-44
  @doc "The number and the content of the newest bundled `compliance_table` version."
  @spec bundled() :: {pos_integer(), content()}
  def bundled, do: {@bundled_no, @bundled}

  @doc "The consent kinds, weakest first."
  @spec kinds() :: [String.t(), ...]
  def kinds, do: ["none", "legitimate_interest", "soft_opt_in", "explicit_opt_in"]

  # PC-40
  # PC-41
  # PC-44
  @doc "Checks the rules of a `compliance_table` version that its JSON Schema cannot express: row identifiers are unique, a country is in one region at most, every legal window ends after it starts and names IANA zones, and a `*` row keeps marketing on explicit opt-in on every channel."
  @spec validate(content()) :: :ok | {:error, Relay.Error.t()}
  def validate(%{"country_rows" => rows, "platform_rows" => platform} = content)
      when is_list(rows) and is_list(platform) do
    checks = [
      unique_rows: unique?(Enum.map(rows ++ platform, & &1["id"])),
      one_region: unique?(Enum.flat_map(regions(content), & &1["countries"])),
      unique_codes: unique?(Enum.map(shared(content), & &1["code"])),
      windows: Enum.all?(rows, &window_valid?/1),
      safe_default: safe_default?(rows)
    ]

    case Enum.find(checks, fn {_rule, ok?} -> not ok? end) do
      nil -> :ok
      {rule, false} -> invalid(rule)
    end
  end

  def validate(_content), do: invalid(:shape)

  defp invalid(rule) do
    {:error,
     Relay.Error.new(:invalid_content, "compliance_table breaks a consistency rule", %{
       rule: rule
     })}
  end

  defp unique?(values), do: length(Enum.uniq(values)) == length(values)

  defp window_valid?(%{"legal_window" => %{"from" => from, "to" => to, "zones" => zones}}) do
    Time.compare(time(from), time(to)) == :lt and
      Enum.all?(zones, &match?({:ok, _zone}, Relay.TimeZone.new(&1)))
  end

  defp window_valid?(_row), do: true

  # PC-41
  defp safe_default?(rows) do
    Enum.any?(rows, fn row ->
      row["country"] == "*" and "marketing" in row["classes"] and
        row["consent"] == ["explicit_opt_in"] and length(row["recipient_types"]) == 2
    end)
  end

  # PC-40
  # PC-47
  @doc "The countries a recipient may be in: the profile country, then the countries of the phone number's country calling code. A code several countries share gives each of the countries the table lists for it."
  @spec candidates(content(), String.t() | nil, String.t() | nil) :: [String.t()]
  def candidates(content, calling_code, profile_country) do
    Enum.uniq(List.wrap(profile_country) ++ phone_countries(content, calling_code))
  end

  defp phone_countries(_content, nil), do: []

  defp phone_countries(content, code) do
    case Enum.find(shared(content), &(&1["code"] == code)) do
      %{"countries" => countries} -> countries
      nil -> List.wrap(Relay.Phone.country("+" <> code))
    end
  end

  # PC-40
  # PC-41
  # PC-42
  # PC-54
  # INV-17
  @doc """
  Resolves what a delivery needs. Every candidate country of the query is read, or the fallback country when there is none, and the most restrictive result decides (PC-40): `required` is the consent kind needed and `accepted` the kinds that satisfy it, `country` and `row` say which row decided (`row` is `nil` when no row asks for anything). `default` is the derived default of a `marketing` cell (PC-14): `:locked_off` when a platform row keeps it off or the country row needs prior consent, otherwise the tenant's choice, as it is for every other class. `legal_windows` are the legal send windows of every matching row and `revocation_channels` the channels on which a revocation also covers this delivery (PC-61). `refusals` come from `Relay.Compliance.Settings.merge/2`.
  """
  @spec resolve(content(), %{optional(String.t()) => [String.t()]}, query()) :: resolution()
  def resolve(%{} = content, refusals, %{} = query) do
    countries = if query.countries == [], do: [query.fallback], else: query.countries
    matches = for country <- countries, do: {country, matching(content, country, query)}

    decisions =
      for {country, rows} <- matches do
        refused = refused(content, refusals, country)
        decide(country, rows, refused)
      end

    decided = Enum.max_by(decisions, & &1.level)
    rows = Enum.flat_map(matches, &elem(&1, 1))
    platform = platform_row(content, query)

    %{
      required: Map.fetch!(@kinds, decided.level),
      accepted: decided.accepted,
      country: decided.country,
      row: decided.row,
      platform_row: platform && platform["id"],
      default: default(query.class, decided.level, platform),
      legal_windows: for(%{"legal_window" => _} = row <- rows, do: window(row)),
      revocation_channels:
        for(
          %{"revocation_scope" => %{"channels" => channels}} <- rows,
          channel <- channels,
          uniq: true,
          do: channel
        )
    }
  end

  defp decide(country, [], _refused),
    do: %{level: 0, accepted: kinds(), country: country, row: nil}

  defp decide(country, rows, refused) do
    rows
    |> Enum.map(fn row ->
      level = level(row["consent"], refused)
      accepted = for kind <- kinds(), @strength[kind] >= level, kind not in refused, do: kind
      %{level: level, accepted: accepted, country: country, row: row["id"]}
    end)
    |> Enum.max_by(& &1.level)
  end

  # INV-17
  defp level(kinds, refused) do
    if "none" in kinds do
      0
    else
      case kinds -- refused do
        [] -> @explicit
        left -> left |> Enum.map(&Map.fetch!(@strength, &1)) |> Enum.min()
      end
    end
  end

  defp refused(content, refusals, country) do
    content |> keys(country) |> Enum.flat_map(&Map.get(refusals, &1, [])) |> Enum.uniq()
  end

  defp keys(content, country) do
    [country | for(region <- regions(content), country in region["countries"], do: region["key"])]
  end

  # PC-14
  # PC-54
  defp default("marketing", _level, %{"default" => "off"}), do: :locked_off
  defp default("marketing", level, _platform) when level > 0, do: :locked_off
  defp default(_class, _level, _platform), do: :tenant

  defp window(%{"id" => id, "legal_window" => window}) do
    %{row: id, from: time(window["from"]), to: time(window["to"]), zones: window["zones"]}
  end

  defp time(text), do: Time.from_iso8601!(text <> ":00")

  # PC-40
  # PC-41
  # PC-43
  @doc "The country rows that govern a delivery to `country`: the rows of the country or of its region that name the channel, the class and the recipient type, or of `*` when the country has no row at all."
  @spec matching(content(), String.t(), query()) :: [row()]
  def matching(content, country, query) do
    own = country_rows(content, country)
    rows = if own == [], do: country_rows(content, "*"), else: own

    Enum.filter(rows, fn row ->
      query.channel in row["channels"] and query.class in row["classes"] and
        query.recipient_type in row["recipient_types"]
    end)
  end

  @doc "Every row of a country: the rows that name it and the rows of the regions it belongs to."
  @spec country_rows(content(), String.t()) :: [row()]
  def country_rows(content, country) do
    keys = keys(content, country)
    Enum.filter(content["country_rows"], &(&1["country"] in keys))
  end

  # PC-54
  @doc "The platform row of a channel and class on a device platform, or `nil`: the row of that platform, otherwise the row that names no platform."
  @spec platform_row(content(), query()) :: row() | nil
  def platform_row(content, query) do
    rows =
      Enum.filter(content["platform_rows"], fn row ->
        query.channel in row["channels"] and query.class in row["classes"]
      end)

    Enum.find(rows, &(&1["platform"] != nil and &1["platform"] == query.platform)) ||
      Enum.find(rows, &(&1["platform"] == nil))
  end

  # PC-39
  # PC-61
  @doc "The revocation scope of a country on a channel: the scope and the channels a revocation received there covers, or `nil` when no row of the country sets one."
  @spec revocation_scope(content(), String.t(), String.t()) ::
          %{scope: String.t(), channels: [String.t()]} | nil
  def revocation_scope(content, country, channel) do
    content
    |> country_rows(country)
    |> Enum.find_value(fn
      %{"channels" => channels, "revocation_scope" => scope} ->
        if channel in channels, do: %{scope: scope["scope"], channels: scope["channels"]}

      _row ->
        nil
    end)
  end

  # TP-33
  @doc "The footer fields a commercial message to `country` on `channel` must carry, in the row's order; empty when no row asks for a footer."
  @spec footer(content(), String.t(), String.t()) :: [String.t()]
  def footer(content, country, channel) do
    content
    |> country_rows(country)
    |> Enum.filter(&(channel in &1["channels"] and "marketing" in &1["classes"]))
    |> Enum.flat_map(&Map.get(&1, "footer", []))
    |> Enum.uniq()
  end

  defp regions(content), do: Map.get(content, "regions", [])
  defp shared(content), do: Map.get(content, "shared_calling_codes", [])
end
