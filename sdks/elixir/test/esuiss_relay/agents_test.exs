defmodule EsuissRelay.AgentsTest do
  use ExUnit.Case, async: true

  alias EsuissRelay.Agents
  alias EsuissRelay.Dedupe
  alias EsuissRelay.Stub

  defp records(ids, cursor, extra \\ %{}) do
    Stub.json(
      200,
      Map.merge(
        %{
          "object" => "mailbox_records",
          "records" => Enum.map(ids, &%{"id" => &1}),
          "cursor" => cursor,
          "has_more" => false,
          "resync_required" => false
        },
        extra
      )
    )
  end

  test "X-30: await_waitpoint polls until the waitpoint is resolved" do
    open = Stub.json(200, %{"id" => "wp_1", "state" => "open"})
    stalled = Stub.json(200, %{"id" => "wp_1", "state" => "stalled"})
    resolved = Stub.json(200, %{"id" => "wp_1", "state" => "resolved", "response" => %{}})
    {client, stub} = Stub.client([open, stalled, resolved])

    assert {:ok, %{"state" => "resolved"}} = Agents.await_waitpoint(client, "wp_1", poll_interval: 10)
    assert length(Stub.requests(stub)) == 3
    assert_received {:slept, 10}
  end

  test "X-30: await_waitpoint gives up with the last state when the time runs out" do
    {client, _stub} = Stub.client([Stub.json(200, %{"id" => "wp_1", "state" => "open"})])

    assert {:error, %EsuissRelay.WaitTimeoutError{waitpoint: %{"state" => "open"}}} =
             Agents.await_waitpoint(client, "wp_1", timeout: 0)
  end

  test "X-30: create, lease and ack call their operations with idempotency keys" do
    lease = Stub.json(200, %{"object" => "mailbox_lease", "lease_id" => "ml_1", "records" => []})
    ack = Stub.json(200, %{"object" => "mailbox_ack", "results" => [], "acked_cursor" => "c"})
    created = Stub.json(201, %{"id" => "wp_1"})
    {client, stub} = Stub.client([created, lease, ack])

    assert {:ok, %{"id" => "wp_1"}} = Agents.create_waitpoint(client, %{"kind" => "event"})
    assert {:ok, %{"lease_id" => "ml_1"}} = Agents.lease(client, 5)
    assert {:ok, _ack} = Agents.ack(client, "ml_1", ["mbr_1"])

    [create, lease_request, ack_request] = Stub.requests(stub)
    assert create.url == "https://relay.test/v1/waitpoints"
    assert JSON.decode!(lease_request.body) == %{"max" => 5}
    assert JSON.decode!(ack_request.body) == %{"lease_id" => "ml_1", "record_ids" => ["mbr_1"]}

    for request <- [create, lease_request, ack_request] do
      assert EsuissRelay.Client.header(request.headers, "idempotency-key")
    end
  end

  test "X-30: follow opens the hints first, reads the history, then reads on every hint once by id" do
    responses = [
      records(["mbr_1", "mbr_2"], "c2", %{"has_more" => true}),
      records(["mbr_2", "mbr_3"], "c3"),
      records(["mbr_3", "mbr_4"], "c4"),
      records([], "c4", %{"resync_required" => true}),
      records(["mbr_1", "mbr_5"], "c5")
    ]

    {client, stub} = Stub.client(responses)
    test = self()

    open_hints = fn ->
      send(test, {:opened, length(Stub.requests(stub))})
      [:hint, :hint]
    end

    assert {:ok, feed} = Agents.follow(client, open_hints, &send(test, {:record, &1["id"]}))

    assert_received {:opened, 0}
    for id <- ~w(mbr_1 mbr_2 mbr_3 mbr_4 mbr_5), do: assert_received({:record, ^id})
    refute_received {:record, _duplicate}
    assert feed.cursor == "c5"

    urls = stub |> Stub.requests() |> Enum.map(& &1.url)

    assert urls == [
             "https://relay.test/v1/mailbox/records",
             "https://relay.test/v1/mailbox/records?since=c2",
             "https://relay.test/v1/mailbox/records?since=c3",
             "https://relay.test/v1/mailbox/records?since=c4",
             "https://relay.test/v1/mailbox/records?since=c4"
           ]
  end

  test "X-30: the dedupe set forgets the oldest ids beyond its limit" do
    dedupe = Dedupe.new(2)
    {true, dedupe} = Dedupe.first?(dedupe, "a")
    {false, dedupe} = Dedupe.first?(dedupe, "a")
    {true, dedupe} = Dedupe.first?(dedupe, "b")
    {true, dedupe} = Dedupe.first?(dedupe, "c")
    assert {true, _dedupe} = Dedupe.first?(dedupe, "a")
  end
end
