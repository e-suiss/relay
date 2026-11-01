defmodule Relay.Datasets.CountryTimeZonesTest do
  use ExUnit.Case, async: true

  alias Relay.Datasets.Package

  defp zones do
    "priv/datasets/country_time_zones/v1.json"
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("zones")
  end

  describe "PC-58 (4) country time zones" do
    test "PC-58: the bundled version is valid and belongs to its data set" do
      assert {:ok, datasets} = Package.read(Package.root())

      assert %{versions: [%{no: 1} | _]} =
               Enum.find(datasets, &(&1.name == "country_time_zones"))
    end

    test "PC-58: every zone is an IANA time zone of the bundled tzdata" do
      for %{"country" => country, "zone" => zone} <- zones() do
        assert {:ok, _} = Relay.TimeZone.new(zone), country
      end
    end

    test "PC-58: country codes are unique, sorted and two uppercase letters" do
      countries = Enum.map(zones(), & &1["country"])

      assert countries == countries |> Enum.uniq() |> Enum.sort()
      assert Enum.all?(countries, &Regex.match?(~r/\A[A-Z]{2}\z/, &1))
    end

    test "PC-58: countries with more than one zone are absent" do
      countries = MapSet.new(zones(), & &1["country"])

      for country <- ~w(US RU BR CA AU MX ID KZ ES PT CL AR CD MN EC DE UA CN) do
        refute MapSet.member?(countries, country), country
      end
    end

    test "PC-58: single zone countries map to their zone" do
      map = Map.new(zones(), &{&1["country"], &1["zone"]})

      assert map["TR"] == "Europe/Istanbul"
      assert map["FR"] == "Europe/Paris"
      assert map["JP"] == "Asia/Tokyo"
      assert map["GB"] == "Europe/London"
    end
  end
end
