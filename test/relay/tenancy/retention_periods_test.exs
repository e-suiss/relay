defmodule Relay.Tenancy.RetentionPeriodsTest do
  use ExUnit.Case, async: true

  @dir "priv/datasets/retention_periods"

  defp read(name), do: @dir |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp periods, do: read("v1.json")["periods"]

  defp period(region, sector, class) do
    Enum.find(
      periods(),
      &(&1["region"] == region and &1["sector"] == sector and
          &1["retention_class"] == class)
    )
  end

  defp validate(schema, value, path \\ "$")

  defp validate(%{"enum" => allowed}, value, path),
    do: if(value in allowed, do: [], else: ["#{path}: #{inspect(value)} not allowed"])

  defp validate(%{"type" => "object"} = schema, value, path) when is_map(value) do
    properties = Map.get(schema, "properties", %{})
    missing = for key <- Map.get(schema, "required", []), not Map.has_key?(value, key), do: key

    extra =
      if schema["additionalProperties"] == false,
        do: Map.keys(value) -- Map.keys(properties),
        else: []

    Enum.map(missing, &"#{path}.#{&1}: missing") ++
      Enum.map(extra, &"#{path}.#{&1}: not allowed") ++
      Enum.flat_map(value, fn {key, item} ->
        case properties do
          %{^key => sub} -> validate(sub, item, "#{path}.#{key}")
          _ -> []
        end
      end)
  end

  defp validate(%{"type" => "array"} = schema, value, path) when is_list(value) do
    size =
      if length(value) < Map.get(schema, "minItems", 0), do: ["#{path}: too few items"], else: []

    size ++
      (value
       |> Enum.with_index()
       |> Enum.flat_map(fn {item, i} -> validate(schema["items"], item, "#{path}[#{i}]") end))
  end

  defp validate(%{"type" => "string"} = schema, value, path) when is_binary(value) do
    length = String.length(value)

    [
      length < Map.get(schema, "minLength", 0) && "#{path}: too short",
      length > Map.get(schema, "maxLength", length) && "#{path}: too long",
      (is_binary(schema["pattern"]) and not Regex.match?(Regex.compile!(schema["pattern"]), value)) &&
        "#{path}: does not match"
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp validate(%{"type" => "integer"} = schema, value, path) when is_integer(value) do
    [
      value < Map.get(schema, "minimum", value) && "#{path}: below minimum",
      value > Map.get(schema, "maximum", value) && "#{path}: above maximum"
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp validate(%{"type" => type}, value, path), do: ["#{path}: #{inspect(value)} is not #{type}"]

  describe "OP-69 retention periods data set" do
    test "OP-69: the packaged version follows the data set's JSON Schema 2020-12" do
      schema = read("schema.json")
      assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
      assert validate(schema, read("v1.json")) == []
      assert validate(schema, %{"source_ref" => "x", "periods" => [%{"region" => "de"}]}) != []
    end

    test "OP-69: the schema names every region and retention class and nothing else" do
      item = read("schema.json")["properties"]["periods"]["items"]["properties"]

      assert Enum.sort(item["region"]["enum"]) ==
               Enum.sort(Enum.map(Relay.Region.all(), &Relay.Region.dump/1))

      assert Enum.sort(item["retention_class"]["enum"]) ==
               Enum.sort(Enum.map(Relay.RetentionClass.all(), &Relay.RetentionClass.dump/1))
    end

    test "OP-69: every row carries its legal basis and each region, sector and class appears once" do
      keys = Enum.map(periods(), &{&1["region"], &1["sector"], &1["retention_class"]})
      assert keys == Enum.uniq(keys)

      for row <- periods() do
        assert row["legal_basis"] != ""
        assert row["source"] =~ "Access Appendix C"
      end

      for region <- ~w(tr eu us), sector <- ~w(general payment bank ecommerce) do
        assert period(region, sector, "audit"), "#{region}/#{sector} has no audit row"
        assert period(region, sector, "erasure_log")["days"] >= 3 * 365
        assert period(region, sector, "dsr_log")["days"] >= 3 * 365
      end
    end

    test "OP-18: classes without a statutory retention have no row" do
      for class <- ~w(recipient_profile notification_content preference suppression) do
        assert Enum.filter(periods(), &(&1["retention_class"] == class)) == [], class
      end
    end

    test "OP-19: commercial message records are kept ten years in Türkiye" do
      for sector <- ~w(general payment bank ecommerce),
          class <- ~w(commercial_consent commercial_message) do
        assert %{"days" => days, "legal_basis" => basis} = period("tr", sector, class)
        assert days >= 3652
        assert basis =~ "6563 m.11(3)"
      end
    end

    test "TN-64: traffic is kept two years in Türkiye, never longer, and has no general period elsewhere" do
      for sector <- ~w(general payment bank ecommerce) do
        assert %{"days" => 730, "legal_basis" => basis} = period("tr", sector, "traffic")
        assert basis =~ "5651 m.5(3)"
        refute period("eu", sector, "traffic")
        refute period("us", sector, "traffic")
      end
    end

    test "TN-49: the general audit retention is 400 days in every region; sector templates extend it" do
      for region <- ~w(tr eu us) do
        assert period(region, "general", "audit")["days"] == 400
      end

      assert period("tr", "payment", "audit")["days"] > 400
      assert period("tr", "bank", "audit")["days"] > 400
      assert period("eu", "payment", "audit")["days"] > 400

      for row <- periods(), row["retention_class"] == "audit", do: assert(row["days"] >= 400)
    end
  end
end
