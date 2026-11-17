defmodule Relay.Agents.ResponseValueTest do
  use ExUnit.Case, async: true

  alias Relay.Agents.ResponseValue

  @schema %{
    "type" => "object",
    "required" => ["decision"],
    "properties" => %{"decision" => %{"enum" => ["accept", "refuse"]}}
  }

  describe "E-86 canonical form of a response value" do
    test "E-86: members are ordered by name and written without whitespace" do
      value = %{"b" => [1, true, nil], "a" => %{"z" => "x", "aa" => false}, "" => "empty"}

      assert ResponseValue.canonical(value) ==
               ~s({"":"empty","a":{"aa":false,"z":"x"},"b":[1,true,null]})
    end

    test "E-86: names are ordered by their UTF-16 code units" do
      value = %{"\u{20AC}" => 1, "\r" => 2, "\u{FB33}" => 3, "1" => 4, "\u{1F600}" => 5}

      assert ResponseValue.canonical(value) ==
               ~s({"\\r":2,"1":4,"\u{20AC}":1,"\u{1F600}":5,"\u{FB33}":3})
    end

    test "E-86: numbers take their shortest ECMAScript form" do
      numbers = [
        {0.0, "0"},
        {-0.0, "0"},
        {1.0, "1"},
        {-12.5, "-12.5"},
        {100.0, "100"},
        {0.000001, "0.000001"},
        {1.0e-7, "1e-7"},
        {1.0e21, "1e+21"},
        {1.5e300, "1.5e+300"},
        {123_456_789.125, "123456789.125"},
        {1.0e20, "100000000000000000000"},
        {42, "42"}
      ]

      for {number, text} <- numbers do
        assert ResponseValue.canonical(number) == text
      end
    end

    test "E-86: the digest is the SHA-256 of the canonical form, whatever the member order" do
      first = Jason.decode!(~s({"decision":"accept","note":"ok"}))
      second = Jason.decode!(~s({"note":"ok","decision":"accept"}))
      canonical = ~s({"decision":"accept","note":"ok"})

      assert ResponseValue.digest(first) == :crypto.hash(:sha256, canonical)
      assert ResponseValue.digest(second) == ResponseValue.digest(first)
      refute ResponseValue.digest(%{"decision" => "refuse"}) == ResponseValue.digest(first)
    end
  end

  describe "INV-31 AG-11 check before anything is recorded" do
    test "INV-31: a value is checked against the response schema" do
      assert ResponseValue.check(@schema, %{"decision" => "accept"}) == :ok
      assert ResponseValue.check(@schema, %{"decision" => "maybe"}) == {:error, :invalid}
      assert ResponseValue.check(@schema, %{}) == {:error, :invalid}
      assert ResponseValue.check(@schema, "accept") == {:error, :invalid}
    end

    test "INV-31: a waitpoint without a response schema takes no response" do
      assert ResponseValue.check(nil, %{"decision" => "accept"}) == {:error, :invalid}
    end

    test "AG-11: a value over the response size limit is refused" do
      limit = Relay.Limits.fetch!(["waitpoint", "max_response_bytes"])
      large = %{"decision" => "accept", "note" => String.duplicate("n", limit)}
      assert ResponseValue.check(%{"type" => "object"}, large) == {:error, :invalid}
    end
  end
end
