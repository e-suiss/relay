defmodule Relay.Templates.SamplesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Templates.Samples

  @letters [?a..?z, ?A..?Z, ?0..?9, ?\s, ?-, ?., ?@]
  @turkish [?ç, ?ğ, ?ı, ?ö, ?ş, ?ü, ?Ç, ?Ğ, ?İ, ?Ö, ?Ş, ?Ü]

  @schema %{
    "type" => "object",
    "properties" => %{
      "name" => %{"type" => "string", "maxLength" => 5},
      "status" => %{"type" => "string", "enum" => ["shipped", "delivered"]},
      "at" => %{"type" => "string", "format" => "date-time"},
      "count" => %{"type" => "integer", "minimum" => 1, "maximum" => 10},
      "paid" => %{"type" => "boolean"},
      "total" => %{
        "type" => "object",
        "properties" => %{
          "amount" => %{"type" => "string", "maxLength" => 8},
          "currency" => %{"type" => "string", "enum" => ["TRY"]}
        }
      },
      "items" => %{
        "type" => "array",
        "minItems" => 1,
        "maxItems" => 3,
        "items" => %{
          "type" => "object",
          "properties" => %{"label" => %{"type" => "string", "maxLength" => 4}}
        }
      }
    }
  }

  describe "TP-47 masking" do
    test "TP-47: letters become X or x by case, digits 0, the rest stays" do
      assert Samples.mask_string("Mehmet Yılmaz") == "Xxxxxx Xxxxxx"
      assert Samples.mask_string("İstanbul 34") == "Xxxxxxxx 00"
      assert Samples.mask_string("ÇĞÜŞÖ çğüşö") == "XXXXX xxxxx"
      assert Samples.mask_string("a-b_c@d.e") == "x-x_x@x.x"
      assert Samples.mask_string("Ali 🎉") == "Xxx 🎉"
      assert Samples.mask_string("مرحبا") == "xxxxx"
    end

    test "TP-47: enum and date-time strings, numbers and booleans are kept" do
      event = %{
        "name" => "Ayşe",
        "status" => "shipped",
        "at" => "2026-01-15T09:30:00Z",
        "count" => 7,
        "paid" => true,
        "items" => [%{"label" => "Kalem 2"}],
        "extra" => "Gizli 9"
      }

      assert Samples.mask(event, @schema) == %{
               "name" => "Xxxx",
               "status" => "shipped",
               "at" => "2026-01-15T09:30:00Z",
               "count" => 7,
               "paid" => true,
               "items" => [%{"label" => "Xxxxx 0"}],
               "extra" => "Xxxxx 0"
             }
    end

    property "TP-47: masking keeps the code point and grapheme counts" do
      check all string <- string(@letters ++ @turkish) do
        masked = Samples.mask_string(string)
        assert length(String.codepoints(masked)) == length(String.codepoints(string))
        assert String.length(masked) == String.length(string)
        refute masked =~ ~r/[a-wyzA-WYZ1-9]/
      end
    end

    test "TP-47: twenty real events from the last seven days" do
      assert Samples.real_event_window() == %{count: 20, days: 7}
    end
  end

  describe "TP-38 sample sources" do
    test "TP-38: boundary samples per variant" do
      samples = Map.new(Samples.boundary(@schema))

      assert Map.keys(samples) |> Enum.sort() == ~w(emoji max min rtl turkish)

      max = samples["max"]
      assert max["name"] == "xxxxx"
      assert max["count"] == 10
      assert max["status"] == "delivered"
      assert max["paid"] == true
      assert length(max["items"]) == 3
      assert max["total"] == %{"amount" => "99999.99", "currency" => "TRY"}
      assert max["at"] == "2026-09-30T23:59:59Z"

      min = samples["min"]
      assert min["name"] == ""
      assert min["count"] == 1
      assert min["status"] == "shipped"
      assert length(min["items"]) == 1
      assert min["total"]["amount"] == "0.00"

      assert samples["turkish"]["name"] == "Çağrı"
      assert samples["emoji"]["name"] == "Ali 🎉"
      assert samples["rtl"]["name"] == "مرحبا"
      assert samples["turkish"]["items"] == [%{"label" => "Çağr"}]
    end

    test "TP-38: references are followed" do
      schema = %{
        "type" => "object",
        "properties" => %{"a" => %{"$ref" => "#/$defs/short"}},
        "$defs" => %{"short" => %{"type" => "string", "maxLength" => 2}}
      }

      assert Map.new(Samples.boundary(schema))["max"] == %{"a" => "xx"}
    end

    test "TP-38: examples come first, then masked real events, then boundary values" do
      schema = Map.put(@schema, "examples", [%{"name" => "Ada"}, "not an object"])
      events = for index <- 1..25, do: %{"name" => "Ayşe #{index}"}

      sources = Samples.sources(schema, events)
      kinds = Enum.map(sources, &elem(&1, 0))

      assert Enum.take(kinds, 1) == [:example]
      assert Enum.count(kinds, &(&1 == :real_event)) == 20
      assert Enum.take(kinds, -5) == List.duplicate(:boundary, 5)
      assert {:example, "example_1", %{"name" => "Ada"}} = hd(sources)
      assert {:real_event, "real_1", %{"name" => "Xxxx 0"}} = Enum.at(sources, 1)
    end
  end
end
