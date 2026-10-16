defmodule Relay.CanonicalTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Canonical

  @vectors [
    {0, "00"},
    {1, "01"},
    {10, "0a"},
    {23, "17"},
    {24, "1818"},
    {25, "1819"},
    {100, "1864"},
    {1000, "1903e8"},
    {1_000_000, "1a000f4240"},
    {1_000_000_000_000, "1b000000e8d4a51000"},
    {18_446_744_073_709_551_615, "1bffffffffffffffff"},
    {-18_446_744_073_709_551_616, "3bffffffffffffffff"},
    {-1, "20"},
    {-10, "29"},
    {-100, "3863"},
    {-1000, "3903e7"},
    {false, "f4"},
    {true, "f5"},
    {nil, "f6"},
    {{:bytes, ""}, "40"},
    {{:bytes, <<1, 2, 3, 4>>}, "4401020304"},
    {"", "60"},
    {"a", "6161"},
    {"IETF", "6449455446"},
    {"\"\\", "62225c"},
    {"ü", "62c3bc"},
    {"水", "63e6b0b4"},
    {[], "80"},
    {[1, 2, 3], "83010203"},
    {[1, [2, 3], [4, 5]], "8301820203820405"},
    {Enum.to_list(1..25), "98190102030405060708090a0b0c0d0e0f101112131415161718181819"},
    {%{}, "a0"},
    {%{1 => 2, 3 => 4}, "a201020304"},
    {%{"a" => 1, "b" => [2, 3]}, "a26161016162820203"},
    {["a", %{"b" => "c"}], "826161a161626163"},
    {%{"a" => "A", "b" => "B", "c" => "C", "d" => "D", "e" => "E"},
     "a56161614161626142616361436164614461656145"}
  ]

  describe "TN-35 canonical serialization" do
    test "TN-35: RFC 8949 appendix A vectors encode as published" do
      for {value, hex} <- @vectors do
        assert Canonical.encode(value) == {:ok, Base.decode16!(hex, case: :lower)}, inspect(value)
      end
    end

    test "TN-35: map keys follow the RFC 8949 4.2.1 bytewise order" do
      map = %{false => 8, [-1] => 7, [100] => 6, "aa" => 5, "z" => 4, -1 => 3, 100 => 2, 10 => 1}

      assert Canonical.encode!(map) ==
               Base.decode16!("a80a011864022003617a0462616105811864068120" <> "07f408",
                 case: :lower
               )
    end

    property "TN-35: map entries are ordered by the bytes of their encoded keys" do
      check all map <-
                  map_of(one_of([string(:printable, max_length: 8), integer()]), integer(),
                    max_length: 23
                  ) do
        entries =
          map
          |> Enum.map(fn {k, v} -> {Canonical.encode!(k), Canonical.encode!(v)} end)
          |> Enum.sort()
          |> Enum.map_join(fn {k, v} -> k <> v end)

        assert Canonical.encode!(map) == <<0xA0 + map_size(map)>> <> entries
      end
    end

    test "TN-35: values without one canonical encoding are refused" do
      for value <- [
            1.5,
            :atom,
            <<0xFF>>,
            {:tuple},
            %{1 => :x},
            [1.0],
            Integer.pow(2, 64),
            -Integer.pow(2, 64) - 1,
            ~D[2026-01-01]
          ] do
        assert {:error, %Relay.Error{code: :not_canonical}} = Canonical.encode(value)
      end

      assert_raise ArgumentError, fn -> Canonical.encode!(1.5) end
    end
  end
end
