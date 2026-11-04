defmodule Relay.Api.SchemaTest do
  use ExUnit.Case, async: true

  alias Relay.Api.Contract
  alias Relay.Api.Schema

  defp pointers(%Relay.Error{details: %{errors: errors}}),
    do: Enum.map(errors, &{&1.pointer, &1.code})

  describe "API-8 strict decoding" do
    test "API-8: an unknown top-level field is unknown_field, never ignored" do
      assert {:error, %Relay.Error{code: :unknown_field} = error} =
               Schema.validate_request("advanceVirtualClock", "application/json", %{
                 "by" => "PT1H",
                 "speed" => 2
               })

      assert {"/speed", "not_allowed"} in pointers(error)
    end

    test "API-8: an unknown field at depth is unknown_field with its pointer" do
      body = %{"events" => [%{"workflow" => "welcome", "to" => [%{"id" => "u-1"}], "bogus" => 1}]}

      assert {:error, %Relay.Error{code: :unknown_field} = error} =
               Schema.validate_request("createEventBatch", "application/json", body)

      assert {"/events/0/bogus", "not_allowed"} in pointers(error)
    end

    test "API-8: null is kept, not treated as absent" do
      assert {:error, %Relay.Error{code: :validation_failed} = error} =
               Schema.validate_request("advanceVirtualClock", "application/json", %{"by" => nil})

      assert {"/by", "invalid_format"} in pointers(error)

      assert {:error, %Relay.Error{code: :validation_failed} = absent} =
               Schema.validate_request("advanceVirtualClock", "application/json", %{})

      assert {"/by", "required"} in pointers(absent)
    end

    test "API-8: a valid body passes" do
      body = %{"by" => "PT1H"}
      assert :ok = Schema.validate_request("advanceVirtualClock", "application/json", body)
    end
  end

  describe "API-37 batch reporting" do
    test "API-37: every field error is reported, not only the first" do
      body = %{"speed" => 2, "pace" => 3}

      assert {:error, error} =
               Schema.validate_request("advanceVirtualClock", "application/json", body)

      assert Enum.sort(pointers(error)) ==
               [{"/by", "required"}, {"/pace", "not_allowed"}, {"/speed", "not_allowed"}]
    end

    test "API-37: length and format failures carry their subcodes" do
      body = %{"by" => "soon"}

      assert {:error, error} =
               Schema.validate_request("advanceVirtualClock", "application/json", body)

      assert pointers(error) == [{"/by", "invalid_format"}]
    end
  end

  describe "API-2 contract schemas" do
    test "API-2: every request schema of the server contract builds" do
      for operation <- Contract.operations(), {type, _schema} <- operation.request do
        assert Schema.request?(operation.id, type)
        assert :ok == valid_or_failed(Schema.validate_request(operation.id, type, %{}))
      end
    end
  end

  describe "E-81 E-83 staged contract fields" do
    test "E-81, E-83: a field of a later stage stays an unknown field until its stage is built" do
      event = %{"workflow" => "welcome", "to" => [%{"id" => "u-1"}]}
      links = [%{"rel" => "primary", "href" => "https://example.com/orders/1"}]

      assert Contract.built_stage() < 6
      assert :ok = Schema.validate_request("createEvent", "application/json", event)

      linked = Map.put(event, "links", links)

      assert {:error, %Relay.Error{code: :unknown_field} = error} =
               Schema.validate_request("createEvent", "application/json", linked)

      assert {"/links", "not_allowed"} in pointers(error)

      batch = %{"events" => [Map.put(event, "correlation_id", "order-1")]}

      assert {:error, %Relay.Error{code: :unknown_field} = error} =
               Schema.validate_request("createEventBatch", "application/json", batch)

      assert {"/events/0/correlation_id", "not_allowed"} in pointers(error)
    end

    test "E-81: a later property is removed with its required entry at every depth" do
      stage = Contract.built_stage()

      schema = %{
        "type" => "object",
        "required" => ["now", "later"],
        "properties" => %{
          "now" => %{"type" => "string", "x-relay-stage" => stage},
          "later" => %{"type" => "string", "x-relay-stage" => stage + 1},
          "nested" => %{
            "type" => "object",
            "properties" => %{"deep" => %{"type" => "integer", "x-relay-stage" => stage + 2}}
          }
        }
      }

      built = Contract.built(schema)

      assert built["required"] == ["now"]
      assert Enum.sort(Map.keys(built["properties"])) == ["nested", "now"]
      assert built["properties"]["nested"]["properties"] == %{}
    end
  end

  defp valid_or_failed(:ok), do: :ok

  defp valid_or_failed({:error, %Relay.Error{code: code}})
       when code in [:validation_failed, :unknown_field],
       do: :ok
end
