defmodule Relay.Api.RealtimeOriginsTest do
  use ExUnit.Case, async: true

  alias Relay.Api.RealtimeOrigins
  alias RelayWeb.Realtime.Origin

  defp codes(environment, origins),
    do: environment |> RealtimeOrigins.errors(origins) |> Enum.map(&{&1.pointer, &1.code})

  describe "IN-54 allowed browser origins" do
    test "IN-54: an origin is https, a lowercase host, no default port, path or wildcard" do
      good = ["https://app.example.com", "https://app.example.com:8443", "https://10.0.0.1"]
      assert codes(:live, good) == []

      bad = [
        "http://app.example.com",
        "https://App.example.com",
        "https://app.example.com/",
        "https://app.example.com:443",
        "https://app.example.com:99999",
        "https://*.example.com",
        "*",
        "null",
        "https://user@app.example.com",
        "https://" <> String.duplicate("a", 250) <> ".com",
        42
      ]

      for origin <- bad do
        assert codes(:live, [origin]) == [{"/origins/0", "invalid_format"}], inspect(origin)
      end
    end

    test "IN-54: only the test environment accepts http://localhost" do
      local = ["http://localhost", "http://localhost:3000"]
      assert codes(:test, local) == []
      invalid = [{"/origins/0", "invalid_format"}, {"/origins/1", "invalid_format"}]
      assert codes(:live, local) == invalid
      assert codes(:test, ["http://localhost:80"]) == [{"/origins/0", "invalid_format"}]
      assert codes(:test, ["http://127.0.0.1:3000"]) == [{"/origins/0", "invalid_format"}]
    end

    test "IN-54: at most 20 origins, each once" do
      many = for n <- 1..21, do: "https://app#{n}.example.com"
      assert {"/origins", "too_long"} in codes(:live, many)
      assert codes(:live, Enum.take(many, 20)) == []

      twice = ["https://a.example.com", "https://a.example.com"]
      assert codes(:live, twice) == [{"/origins/1", "conflict"}]
    end

    test "IN-54: the match is exact and a client without Origin is not affected" do
      origins = ["https://app.example.com"]
      assert RealtimeOrigins.allowed?(origins, "https://app.example.com")
      refute RealtimeOrigins.allowed?(origins, "https://app.example.com:8443")
      refute RealtimeOrigins.allowed?(origins, "https://evil.app.example.com")
      refute RealtimeOrigins.allowed?([], "https://app.example.com")
      assert RealtimeOrigins.allowed?([], nil)
    end

    test "IN-54: a handshake origin is written back as its Origin header text" do
      text = &Origin.text(URI.parse(&1))
      assert text.("https://app.example.com") == "https://app.example.com"
      assert text.("https://app.example.com:443") == "https://app.example.com"
      assert text.("https://app.example.com:8443") == "https://app.example.com:8443"
      assert text.("http://localhost:3000") == "http://localhost:3000"
      assert text.("null") == "null"
      assert text.("https://app.example.com/x") == "null"
    end

    test "IN-54: the check_origin hook notes the origin for the transport and never refuses" do
      assert Origin.take() == nil
      assert Origin.record(URI.parse("https://app.example.com")) == true
      assert Origin.take() == "https://app.example.com"
      assert Origin.take() == nil
    end
  end
end
