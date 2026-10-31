defmodule Relay.Ingest.CloudEventsTest do
  use ExUnit.Case, async: true

  @vectors "test/vectors/ingest/cloudevents_keys_v1.json" |> File.read!() |> Jason.decode!()

  describe "API-31 API-28 derived keys" do
    test "API-31: the derived keys follow the vectors over deterministic CBOR" do
      for v <- @vectors["vectors"] do
        cbor = Relay.Canonical.encode!([v["purpose"], v["source"], v["id"]])
        assert Base.encode16(cbor, case: :lower) == v["cbor"], v["name"]

        key =
          case v["purpose"] do
            "relay.ce_idempotency.v1" -> Relay.Ingest.ce_idempotency_key(v["source"], v["id"])
            "relay.ce_dedup.v1" -> Relay.Ingest.ce_dedup_key(v["source"], v["id"])
          end

        assert String.slice(key, 3..-1//1) == v["sha256"], v["name"]
        assert String.length(key) == 67
      end
    end

    test "API-31: a batch key covers every (source, id) pair in order" do
      a = Relay.Ingest.ce_batch_key([{"s", "1"}, {"s", "2"}])
      b = Relay.Ingest.ce_batch_key([{"s", "2"}, {"s", "1"}])
      assert "ce_" <> _ = a
      refute a == b
    end
  end

  describe "API-28 binary mode and mapping" do
    test "API-28: a binary mode event is read from its ce-* headers" do
      headers = [
        {"ce-specversion", "1.0"},
        {"ce-id", "1"},
        {"ce-source", "/shop"},
        {"ce-type", "order.shipped"},
        {"content-type", "application/json"}
      ]

      assert {:ok, event} = Relay.Ingest.ce_from_binary(headers, %{"a" => 1})
      assert event["data"] == %{"a" => 1}
      assert event["type"] == "order.shipped"
    end

    test "API-28: an unknown ce-* attribute is unknown_field and a missing id is required" do
      assert {:error, %Relay.Error{code: :unknown_field}} =
               Relay.Ingest.ce_from_binary(
                 [{"ce-specversion", "1.0"}, {"ce-partitionkey", "p"}],
                 %{}
               )

      assert {:error, %Relay.Error{code: :validation_failed, details: %{errors: errors}}} =
               Relay.Ingest.ce_from_binary(
                 [{"ce-specversion", "1.0"}, {"ce-source", "/s"}, {"ce-type", "t"}],
                 %{}
               )

      assert [%{pointer: "/headers/ce-id", code: "required"}] = errors
    end

    test "MD-16: only allow-listed data fields reach the event" do
      data = %{"order" => %{"id" => "A"}, "card" => "4111", "to" => "user-1", "org" => "stn_x"}

      mapping = %{
        "to_pointer" => "/to",
        "tenant_pointer" => "/org",
        "data_fields" => ["/order/id"]
      }

      assert {:ok, request} = Relay.Ingest.ce_map(%{"data" => data}, mapping)
      assert request["to"] == ["user-1"]
      assert request["tenant"] == "stn_x"
      assert request["data"] == %{"order" => %{"id" => "A"}}
    end
  end
end
