import Foundation
import XCTest

@testable import EsuissRelay

final class RealtimeTests: XCTestCase {
  func testIN23ServerSentEventParser() {
    var splitter = LineSplitter()
    var parser = ServerSentEventParser()
    let stream =
      ": keep-alive\r\nevent: inbox.counters_changed\nid: c7\ndata: {\"a\":\ndata: 1}\n\n\n"
    var events: [ServerSentEvent] = []
    for byte in Array(stream.utf8) {
      if let line = splitter.feed(byte), let event = parser.feed(line: line) {
        events.append(event)
      }
    }
    XCTAssertEqual(
      events, [ServerSentEvent(event: "inbox.counters_changed", data: "{\"a\":\n1}", id: "c7")])
  }

  func testIN23PhoenixFramesAndTokenSubprotocol() throws {
    let frame = PhoenixFrame(
      joinRef: "1",
      ref: "1",
      topic: "inbox",
      event: "phx_join",
      payload: Data("{\"cursor\":\"c1\"}".utf8)
    )
    let decoded = try XCTUnwrap(PhoenixFrame.decode(frame.encoded()))
    XCTAssertEqual(decoded.topic, "inbox")
    XCTAssertEqual(decoded.event, "phx_join")
    XCTAssertEqual(decoded.joinRef, "1")
    let payload = try JSONSerialization.jsonObject(with: decoded.payload) as? [String: String]
    XCTAssertEqual(payload, ["cursor": "c1"])
    let heartbeat = PhoenixFrame(
      joinRef: nil, ref: "2", topic: "phoenix", event: "heartbeat", payload: Data("{}".utf8))
    XCTAssertTrue(heartbeat.encoded().hasPrefix("[null,"))
    XCTAssertEqual(
      PhoenixFrame.subprotocols(token: "a?b>"), ["phoenix", "base64url.bearer.phx.YT9iPg"])
  }

  func testIN33IN52CloseReasons() {
    XCTAssertEqual(
      WebSocketRealtimeTransport.stop(reason: "retry-after=4", joined: true), .retryAfter(4))
    XCTAssertEqual(
      WebSocketRealtimeTransport.stop(reason: "auth_expired_token", joined: true), .authExpired)
    XCTAssertEqual(
      WebSocketRealtimeTransport.stop(reason: "auth_subscriber_suspended", joined: true),
      .refused("auth_subscriber_suspended")
    )
    XCTAssertEqual(WebSocketRealtimeTransport.stop(reason: nil, joined: false), .unavailable)
    XCTAssertEqual(WebSocketRealtimeTransport.stop(reason: nil, joined: true), .closed)
    XCTAssertEqual(
      ServerSentEventsRealtimeTransport.stop(status: 503, retryAfter: 3), .retryAfter(3))
    XCTAssertEqual(
      ServerSentEventsRealtimeTransport.stop(status: 401, retryAfter: nil), .authExpired)
  }

  func testIN26EnvelopeDecoding() throws {
    let created = try XCTUnwrap(
      RelayRealtimeEnvelope(
        json: Data(
          """
          {"t":"inbox.item_created","v":1,"ts":"2026-11-01T09:30:00Z","id":"c1",\
          "d":{"item":\(Fixtures.item()),"state_version":1},\
          "counters":{"unseen":1,"unread":1,"total":1,"version":2}}
          """.utf8
        )
      )
    )
    XCTAssertEqual(created.counters.version, 2)
    let item = try XCTUnwrap(created.createdItem)
    XCTAssertEqual(item.id, Fixtures.itemId)
    XCTAssertFalse(item.thin)
    let decoded = try XCTUnwrap(RelayInboxStore.decodeItem(item.json))
    XCTAssertEqual(decoded.title, "Order shipped")
    XCTAssertEqual(decoded.url?.absoluteString, "https://shop.test/orders/1")
    XCTAssertNil(created.itemPatch)
  }

  func testIN34FallsBackFromWebSocketToSSEAndBacksOffWithJitter() async throws {
    let harness = Harness()
    let log = Recorder()
    let webSocket = ScriptedTransport(kind: .webSocket, log: log, script: [.unavailable])
    let sse = ScriptedTransport(
      kind: .serverSentEvents, log: log, script: [.retryAfter(3), .closed])
    let poll = ScriptedTransport(kind: .longPoll, log: log, script: [])
    let connection = RelayRealtimeConnection(
      transports: [webSocket, sse, poll],
      tokens: TokenStore(provider: harness.tokens, clock: harness.clock),
      clock: harness.clock,
      random: FixedRandom(value: 0.5)
    )
    await connection.connect(cursor: "c1")
    for _ in 0..<100_000 where log.values.count < 4 { await Task.yield() }
    await connection.disconnect()
    let calls = log.values
    XCTAssertEqual(Array(calls.prefix(3)), ["websocket:c1", "sse:c1", "sse:c1"])
    let sleeps = harness.clock.recordedSleeps
    XCTAssertGreaterThanOrEqual(sleeps.first ?? 0, 3)
    XCTAssertEqual(sleeps.dropFirst().first, 1.0)
  }

  func testIN33RefusedConnectionStops() async {
    let harness = Harness()
    let log = Recorder()
    let webSocket = ScriptedTransport(
      kind: .webSocket, log: log, script: [.refused("auth_tenant_suspended")])
    let connection = RelayRealtimeConnection(
      transports: [webSocket],
      tokens: TokenStore(provider: harness.tokens, clock: harness.clock),
      clock: harness.clock,
      random: FixedRandom()
    )
    await connection.connect(cursor: nil)
    for _ in 0..<100_000 {
      let current = await connection.state
      if case .stopped = current { break }
      await Task.yield()
    }
    let state = await connection.state
    XCTAssertEqual(state, .stopped("auth_tenant_suspended"))
    XCTAssertEqual(log.values, ["websocket:-"])
  }
}

struct ScriptedTransport: RelayRealtimeTransport {
  let kind: RelayRealtimeTransportKind
  let log: Recorder
  let script: [RelayRealtimeStop]

  func run(
    cursor: String?,
    token: String,
    onOpen: @escaping @Sendable () async -> Void,
    onEnvelope: @escaping @Sendable (RelayRealtimeEnvelope) async -> Void
  ) async throws {
    let calls = log.values.filter { $0.hasPrefix(kind.rawValue + ":") }.count
    log.append("\(kind.rawValue):\(cursor ?? "-")")
    if calls < script.count { throw script[calls] }
    await onOpen()
    while !Task.isCancelled { await Task.yield() }
  }
}
