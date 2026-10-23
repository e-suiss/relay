defmodule Relay.Datasets.SchemaTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Datasets.Schema

  @schema %{
    "$schema" => "https://json-schema.org/draft/2020-12/schema",
    "type" => "object",
    "required" => ["rows"],
    "properties" => %{
      "rows" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "required" => ["code", "class"],
          "properties" => %{
            "code" => %{"type" => "string", "pattern" => "^[0-9]{3}$"},
            "class" => %{"enum" => ["transient", "permanent"]}
          },
          "additionalProperties" => false
        }
      }
    },
    "$defs" => %{"unused" => %{"type" => "null"}},
    "unevaluatedProperties" => false
  }

  describe "OP-65 (1) JSON Schema 2020-12 validation" do
    test "OP-65: content that matches the schema passes, content that does not is refused" do
      {:ok, root} = Schema.build(@schema)

      assert Schema.validate(root, %{"rows" => [%{"code" => "421", "class" => "transient"}]}) ==
               :ok

      for bad <- [
            %{},
            %{"rows" => [%{"code" => "42", "class" => "transient"}]},
            %{"rows" => [%{"code" => "421", "class" => "maybe"}]},
            %{"rows" => [], "extra" => 1}
          ] do
        assert {:error, %Relay.Error{code: :invalid_content, details: %{errors: n}}} =
                 Schema.validate(root, bad)

        assert n >= 1
      end
    end

    test "OP-65: a schema of another dialect or one that is not a schema is refused" do
      assert {:error, %Relay.Error{code: :invalid_schema}} =
               Schema.build(
                 Map.put(@schema, "$schema", "http://json-schema.org/draft-07/schema#")
               )

      assert {:error, %Relay.Error{code: :invalid_schema}} = Schema.build(["not", "a", "schema"])
      assert {:error, %Relay.Error{code: :invalid_schema}} = Schema.build(%{"type" => 12})
      assert {:ok, _} = Schema.build(Map.delete(@schema, "$schema"))
    end

    test "OP-65: references never leave the schema" do
      assert {:error, %Relay.Error{code: :invalid_schema}} =
               Schema.build(%{"$ref" => "https://example.com/remote.json"})
    end
  end

  describe "OP-65 (2) content digest" do
    property "OP-65: the digest does not depend on key order" do
      check all pairs <-
                  uniq_list_of({string(:alphanumeric), integer()},
                    uniq_fun: &elem(&1, 0),
                    max_length: 8
                  ) do
        map = Map.new(pairs)
        reversed = pairs |> Enum.reverse() |> Map.new()
        assert Schema.digest(map) == Schema.digest(reversed)
      end
    end

    test "TN-65: the digest is SHA-256 of the deterministic CBOR encoding; floats are refused" do
      value = %{"b" => [1, "x", nil, true], "a" => %{"c" => -5}}

      assert Schema.digest(value) ==
               {:ok, :crypto.hash(:sha256, Relay.Canonical.encode!(value))}

      assert {:error, %Relay.Error{code: :not_canonical}} = Schema.digest(%{"price" => 0.05})
    end
  end
end
