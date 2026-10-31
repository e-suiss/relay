defmodule Relay.Api.VersionsTest do
  use ExUnit.Case, async: true

  alias Relay.Api.Versions

  defmodule Rename do
    @moduledoc false
    @behaviour Relay.Api.Versions.Converter

    @impl true
    def request(_operation, body), do: Map.update(body, "steps", [], &["rename" | &1])

    @impl true
    def response(_operation, body), do: Map.update(body, "steps", [], &["rename" | &1])
  end

  defmodule Split do
    @moduledoc false
    @behaviour Relay.Api.Versions.Converter

    @impl true
    def request(_operation, body), do: Map.update(body, "steps", [], &["split" | &1])

    @impl true
    def response(_operation, body), do: Map.update(body, "steps", [], &["split" | &1])
  end

  describe "API-52 dated versions" do
    test "API-52: the supported list and the latest version are the contract's" do
      %{supported: supported, latest: latest} = Relay.Api.Contract.api_versions()
      assert Versions.supported() == supported
      assert Versions.latest() == latest
      assert latest in supported
    end

    test "API-52: an unsupported or malformed value is unsupported_api_version with the list" do
      for value <- ["2020-01-01", "latest", "2026-11-1", ""] do
        assert {:error, %Relay.Error{code: :unsupported_api_version, details: details}} =
                 Versions.parse(value)

        assert details.supported_versions == Versions.supported()
      end

      assert {:ok, "2026-11-01"} = Versions.parse("2026-11-01")
    end

    test "API-52: the header wins, then the pin; the latest version is only a pin, never a default" do
      assert Versions.resolve("2026-11-01", "2027-01-01") == {"2026-11-01", :header}
      assert Versions.resolve(nil, "2026-11-01") == {"2026-11-01", :pinned}
      assert Versions.resolve(nil, nil) == {Versions.latest(), :pin}
    end
  end

  describe "API-54 support window" do
    test "API-54: a version announced for removal carries Deprecation, Sunset and Link" do
      lifecycle = %{
        "2026-11-01" => %{
          deprecated_at: ~U[2027-01-01 00:00:00Z],
          sunset_at: ~U[2028-11-01 00:00:00Z],
          link: "https://relay.example.com/changelog/2026-11-01"
        }
      }

      assert Versions.headers("2026-11-01", lifecycle) == [
               {"deprecation", "@1798761600"},
               {"sunset", "Wed, 01 Nov 2028 00:00:00 GMT"},
               {"link", ~s(<https://relay.example.com/changelog/2026-11-01>; rel="deprecation")}
             ]

      assert Versions.headers("2026-11-01") == []
    end

    test "API-54: requests climb the converter chain and responses descend it" do
      converters = [{"2027-06-01", Split}, {"2027-01-01", Rename}]

      assert Versions.request("2027-01-01", "op", %{"steps" => []}, converters) ==
               %{"steps" => ["split", "rename"]}

      assert Versions.response("2027-01-01", "op", %{"steps" => []}, converters) ==
               %{"steps" => ["rename", "split"]}

      assert Versions.request("2027-06-01", "op", %{"steps" => []}, converters) ==
               %{"steps" => ["split"]}

      assert Versions.request(Versions.latest(), "op", %{"a" => 1}) == %{"a" => 1}
    end
  end
end
