defmodule Relay.Webhooks.BatchTest do
  use ExUnit.Case, async: true

  alias Relay.Webhooks.Batch

  @opened ~U[2026-11-16 08:00:00Z]
  @limits %{max_age_ms: 300_000, max_bytes: 100, max_events: 3}

  defp after_ms(ms), do: DateTime.add(@opened, ms, :millisecond)

  describe "WH-21 object name" do
    test "WH-21: the name comes from the batch identifier alone" do
      assert Batch.object_key(nil, "whb_01JCX5") == "whb_01JCX5.jsonl"
      assert Batch.object_key("", "whb_01JCX5") == "whb_01JCX5.jsonl"
      assert Batch.object_key("events", "whb_01JCX5") == "events/whb_01JCX5.jsonl"
      assert Batch.object_key("events/", "whb_01JCX5") == "events/whb_01JCX5.jsonl"
      assert Batch.object_key("a/b", "whb_01JCX5") == Batch.object_key("a/b", "whb_01JCX5")
    end

    test "WH-21: an identifier that is not a plain file name is replaced by its digest" do
      digest = Base.encode16(:crypto.hash(:sha256, "../other"), case: :lower)

      assert Batch.object_key("events", "../other") == "events/" <> digest <> ".jsonl"
      assert Batch.object_key(nil, ".hidden") =~ ~r/\A[0-9a-f]{64}\.jsonl\z/
      assert Batch.object_key(nil, "a b") =~ ~r/\A[0-9a-f]{64}\.jsonl\z/
    end
  end

  describe "WH-21 JSON lines" do
    test "WH-21: every body is one line, in order, and the same bodies give the same bytes" do
      bodies = [~s({"id":"evt_1"}), ~s({"id":"evt_2"})]

      assert Batch.encode(bodies) == {:ok, ~s({"id":"evt_1"}\n{"id":"evt_2"}\n)}
      assert Batch.encode(bodies) == Batch.encode(bodies)
      assert Batch.encode([]) == {:ok, ""}
      assert Batch.content_type() == "application/x-ndjson"
    end

    test "WH-21: a body that is not one line is refused with its position" do
      assert Batch.encode([~s({"a":1}), "{\n}"]) == {:error, {:not_a_line, 1}}
      assert Batch.encode(["{}\r"]) == {:error, {:not_a_line, 0}}
      assert Batch.encode([""]) == {:error, {:not_a_line, 0}}
    end

    test "WH-21: the message of a batch carries the identifier and the lines" do
      assert {:ok, message} = Batch.prepared("whb_1", [~s({"id":"evt_1"})], 2)

      assert %{id: "whb_1", attempt: 2, content_type: "application/x-ndjson"} = message
      assert message.body == ~s({"id":"evt_1"}\n)
      assert message.partition_key == nil
      assert Batch.prepared("whb_1", ["a\nb"], 1) == {:error, {:not_a_line, 0}}
    end
  end

  describe "WH-21 closing rule" do
    test "WH-21: a batch counts its events and its bytes, line breaks included" do
      batch = "whb_1" |> Batch.open(@opened) |> Batch.add("12345") |> Batch.add("123")

      assert %Batch{id: "whb_1", opened_at: @opened, events: 2, bytes: 10} = batch
    end

    test "WH-21: an empty batch is never closed and takes any event" do
      batch = Batch.open("whb_1", @opened)

      assert Batch.close_reason(batch, after_ms(900_000), @limits) == nil
      assert Batch.accepts?(batch, String.duplicate("a", 500), @limits)
    end

    test "WH-21: the event count closes a batch" do
      open = Batch.open("whb_1", @opened)
      batch = open |> Batch.add("a") |> Batch.add("a") |> Batch.add("a")

      assert Batch.close_reason(batch, @opened, @limits) == :events
      refute Batch.accepts?(batch, "a", @limits)
    end

    test "WH-21: the size closes a batch" do
      batch = Batch.add(Batch.open("whb_1", @opened), String.duplicate("a", 99))

      assert Batch.close_reason(batch, @opened, @limits) == :bytes
      refute Batch.accepts?(batch, "a", @limits)
    end

    test "WH-21: an event that would pass the size limit does not join an open batch" do
      batch = Batch.add(Batch.open("whb_1", @opened), String.duplicate("a", 49))

      assert Batch.close_reason(batch, @opened, @limits) == nil
      assert Batch.accepts?(batch, String.duplicate("a", 49), @limits)
      refute Batch.accepts?(batch, String.duplicate("a", 50), @limits)
    end

    test "WH-21: the age closes a batch, whichever limit comes first" do
      batch = Batch.add(Batch.open("whb_1", @opened), "a")

      assert Batch.close_reason(batch, after_ms(299_999), @limits) == nil
      assert Batch.close_reason(batch, after_ms(300_000), @limits) == :age
      assert Batch.closes_at(batch, @limits) == after_ms(300_000)

      full = batch |> Batch.add("a") |> Batch.add("a")
      assert Batch.close_reason(full, after_ms(300_000), @limits) == :events
    end
  end
end
