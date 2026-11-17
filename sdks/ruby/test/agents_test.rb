# frozen_string_literal: true

require "test_helper"

class AgentsTest < Minitest::Test
  include TestSupport

  def waitpoint(state, interval = nil)
    body = { "object" => "waitpoint", "id" => "wp_1", "state" => state }
    body["heartbeat_interval"] = interval if interval
    TestSupport.json(200, body)
  end

  def clocked_client(transport)
    now = [0.0]
    sleeps = []
    client = Esuiss::Relay::Client.new(base_url: "https://relay.test", auth: StubAuth.new, transport: transport,
                                       sleeper: lambda { |seconds|
                                         sleeps << seconds
                                         now[0] += seconds
                                       },
                                       monotonic: -> { now[0] })
    [client, sleeps]
  end

  def test_x30_open_waitpoint_keeps_its_idempotency_key
    transport = StubTransport.new(waitpoint("open"))
    client, = clocked_client(transport)
    handle = client.open_waitpoint({ "kind" => "event" }, idempotency_key: "wp-order-1")

    assert_equal "wp_1", handle.id
    assert_equal "wp-order-1", handle.idempotency_key
    assert_equal "wp-order-1", transport.requests.first.headers["Idempotency-Key"]
    assert_equal "https://relay.test/v1/waitpoints", transport.requests.first.url
  end

  def test_x30_await_waitpoint_polls_and_heartbeats_until_terminal
    transport = StubTransport.new(*Array.new(6) { waitpoint("open", "PT10S") }, waitpoint("resolved"))
    client, sleeps = clocked_client(transport)
    result = client.await_waitpoint("wp_1", timeout: 60, poll_interval: 3)

    assert_equal "resolved", result["state"]
    heartbeats = transport.requests.count { |r| r.url.end_with?("/heartbeat") }

    assert_equal 2, heartbeats
    assert(sleeps.all?(3))
  end

  def test_x30_await_waitpoint_times_out
    transport = StubTransport.new(*Array.new(5) { waitpoint("open") })
    client, = clocked_client(transport)

    assert_raises(Esuiss::Relay::WaitTimeoutError) do
      client.await_waitpoint("wp_1", timeout: 5, poll_interval: 2, heartbeat: false)
    end
  end

  def test_x30_mailbox_read_lease_and_ack
    records = { "object" => "mailbox_records", "records" => [{ "id" => "mbr_1" }], "cursor" => "k1",
                "has_more" => true, "resync_required" => false }
    last = records.merge("records" => [{ "id" => "mbr_2" }], "cursor" => "k2", "has_more" => false)
    lease = { "object" => "mailbox_lease", "lease_id" => "lse_1", "lease_expires_at" => "2026-11-18T10:00:00Z",
              "records" => [{ "id" => "mbr_1" }, { "id" => "mbr_2" }] }
    transport = StubTransport.new(TestSupport.json(200, records), TestSupport.json(200, last),
                                  TestSupport.json(200, lease), TestSupport.json(200, { "object" => "mailbox_ack" }))
    client, = clocked_client(transport)

    assert_equal(%w[mbr_1 mbr_2], client.read_mailbox(limit: 1).map { |r| r["id"] })
    assert_includes transport.requests[1].url, "since=k1"
    seen = []

    assert_equal 2, client.consume_mailbox(max: 2) { |record| seen << record["id"] }
    ack = transport.requests.last

    assert_equal({ "lease_id" => "lse_1", "record_ids" => %w[mbr_1 mbr_2] }, JSON.parse(ack.body))
    assert_equal({ "max" => 2 }, JSON.parse(transport.requests[2].body))
    refute_nil ack.headers["Idempotency-Key"]
  end

  def test_x30_consume_mailbox_acks_only_handled_records_when_the_handler_fails
    lease = { "lease_id" => "lse_1", "records" => [{ "id" => "mbr_1" }, { "id" => "mbr_2" }] }
    transport = StubTransport.new(TestSupport.json(200, lease), TestSupport.json(200, {}))
    client, = clocked_client(transport)

    assert_raises(RuntimeError) do
      client.consume_mailbox { |record| raise "boom" if record["id"] == "mbr_2" }
    end
    assert_equal %w[mbr_1], JSON.parse(transport.requests.last.body).fetch("record_ids")
  end

  def test_in28_stream_is_opened_first_then_history_then_deduplicated
    order = []
    stream = lambda {
      order << :stream
      [{ "id" => "a", "seq" => 2 }, { "id" => "b", "seq" => 1 },
       { "id" => "c", "seq" => 1 }, { "id" => "a", "seq" => 3 }]
    }
    history = lambda {
      order << :history
      [{ "id" => "a", "seq" => 2 }, { "id" => "b", "seq" => 1 }]
    }
    client, = clocked_client(StubTransport.new)
    merged = client.merge_stream_and_history(stream, history).to_a

    assert_equal %i[stream history], order
    assert_equal([%w[a 2], %w[b 1], %w[c 1], %w[a 3]], merged.map { |i| [i["id"], i["seq"].to_s] })
  end

  def test_x30_iso8601_durations
    assert_in_delta(10.0, Esuiss::Relay::Agents.duration_seconds("PT10S"))
    assert_in_delta(90_061.0, Esuiss::Relay::Agents.duration_seconds("P1DT1H1M1S"))
    assert_nil Esuiss::Relay::Agents.duration_seconds("PT")
    assert_nil Esuiss::Relay::Agents.duration_seconds(nil)
  end
end
