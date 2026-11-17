import Foundation
import XCTest

@testable import EsuissRelay

final class InboxTests: XCTestCase {
  func testIN13QueueIsCompactedPerItemAndOrderedByClientSeq() async {
    let queue = IntentQueue(storage: MemoryIntentQueueStorage())
    await queue.enqueue(itemId: "inb_a", operation: .read, baseStateVersion: 1)
    await queue.enqueue(itemId: "inb_b", operation: .archive, baseStateVersion: 4)
    await queue.enqueue(itemId: "inb_a", operation: .unread, baseStateVersion: 2)
    let pending = await queue.pending()
    XCTAssertEqual(pending.map(\.itemId), ["inb_b", "inb_a"])
    XCTAssertEqual(pending.map(\.operation), [.archive, .unread])
    XCTAssertEqual(pending.map(\.clientSeq), [1, 2])
  }

  func testIN13OlderReverseIntentIsDroppedAndMonotoneStays() async {
    let queue = IntentQueue(storage: MemoryIntentQueueStorage())
    await queue.enqueue(itemId: "inb_a", operation: .unread, baseStateVersion: 2)
    await queue.enqueue(itemId: "inb_b", operation: .read, baseStateVersion: 2)
    await queue.observe(itemId: "inb_a", stateVersion: 3)
    await queue.observe(itemId: "inb_b", stateVersion: 3)
    let pending = await queue.pending()
    XCTAssertEqual(pending.map(\.itemId), ["inb_b"])
  }

  func testIN13QueueSurvivesARestart() async {
    let storage = MemoryIntentQueueStorage()
    let first = IntentQueue(storage: storage)
    await first.enqueue(itemId: "inb_a", operation: .archive, baseStateVersion: 1)
    let second = IntentQueue(storage: storage)
    let pending = await second.pending()
    XCTAssertEqual(pending.count, 1)
    let next = await second.enqueue(itemId: "inb_b", operation: .read, baseStateVersion: 1)
    XCTAssertEqual(next.clientSeq, 1)
  }

  @MainActor
  func testIN12ConflictIsAcceptedSilentlyUnlessTheUserJustReversed() async throws {
    let harness = Harness()
    let client = harness.client()
    harness.transport.enqueue(
      "listMyInboxItems",
      .json(
        200,
        """
        {"object":"list","data":[\(Fixtures.item(version: 2, read: true))],"has_more":false,\
        "next_cursor":null,"previous_cursor":null,\
        "counters":\(Fixtures.counters(unseen: 0, unread: 0, version: 4)),"cursor":"c1"}
        """
      )
    )
    await client.store.coldSync()
    XCTAssertEqual(client.store.items.count, 1)
    let item = try XCTUnwrap(client.store.items.first)
    harness.transport.enqueue(
      "applyMyInboxIntent",
      .problem(
        409,
        code: "inbox_item_conflict",
        retryable: false,
        extra: ",\"current\":\(Fixtures.state(version: 5, read: true))"
      )
    )
    await client.store.perform(.unread, on: item)
    XCTAssertEqual(client.store.notice, .updatedOnAnotherDevice(itemId: Fixtures.itemId))
    XCTAssertEqual(client.store.items.first?.read, true)
    XCTAssertEqual(client.store.items.first?.stateVersion, 5)
    let intent = try XCTUnwrap(harness.transport.requests("applyMyInboxIntent").first)
    XCTAssertEqual(intent.json["op"] as? String, "unread")
    XCTAssertEqual(intent.json["base_state_version"] as? Int, 2)
    XCTAssertNotNil(intent.json["client_seq"])
    let empty = await client.store.queue.isEmpty
    XCTAssertTrue(empty)
  }

  @MainActor
  func testIN13OfflineIntentStaysQueuedUntilTheServerAnswers() async throws {
    let harness = Harness()
    let client = harness.client()
    harness.transport.enqueue(
      "listMyInboxItems",
      .json(
        200,
        """
        {"object":"list","data":[\(Fixtures.item(version: 2))],"has_more":false,"next_cursor":null,\
        "previous_cursor":null,"counters":\(Fixtures.counters(unseen: 1, unread: 1, version: 4)),\
        "cursor":"c1"}
        """
      )
    )
    await client.store.coldSync()
    let item = try XCTUnwrap(client.store.items.first)
    await client.store.perform(.read, on: item)
    XCTAssertEqual(client.store.items.first?.read, true)
    XCTAssertEqual(client.store.counters.unread, 0)
    var pending = await client.store.queue.pending()
    XCTAssertEqual(pending.map(\.operation), [.read])
    harness.transport.enqueue(
      "applyMyInboxIntent",
      .json(
        200,
        """
        {"object":"inbox_intent_result","item_id":"\(Fixtures.itemId)","op":"read","client_seq":0,\
        "result":"applied","state":\(Fixtures.state(version: 3, read: true)),\
        "counters":\(Fixtures.counters(unseen: 0, unread: 0, version: 5))}
        """
      )
    )
    await client.store.drainQueue()
    pending = await client.store.queue.pending()
    XCTAssertTrue(pending.isEmpty)
    XCTAssertEqual(client.store.counters.version, 5)
    let keys = Set(harness.transport.requests("applyMyInboxIntent").compactMap { $0.header("Idempotency-Key") })
    XCTAssertEqual(keys.count, 1)
  }

  @MainActor
  func testIN18OlderCountersAreIgnored() {
    let harness = Harness()
    let client = harness.client()
    client.store.apply(counters: RelayInboxCounters(unseen: 3, unread: 3, total: 3, version: 10))
    client.store.apply(counters: RelayInboxCounters(unseen: 9, unread: 9, total: 9, version: 9))
    XCTAssertEqual(client.store.counters.unseen, 3)
  }

  @MainActor
  func testIN28RealtimeUpdateAppliesOnlyANewerStateAndIN38RemovesTheNotification() async throws {
    let harness = Harness()
    let delivered = FakeDelivered([
      RelayDeliveredNotification(identifier: "n1", relayId: Fixtures.deliveryId, topic: "order-1")
    ])
    let client = harness.client(delivered: delivered)
    harness.transport.enqueue(
      "listMyInboxItems",
      .json(
        200,
        """
        {"object":"list","data":[\(Fixtures.item(version: 2))],"has_more":false,"next_cursor":null,\
        "previous_cursor":null,"cursor":"c1"}
        """
      )
    )
    await client.store.coldSync()
    let stale = try XCTUnwrap(
      RelayRealtimeEnvelope(
        json: Data(
          """
          {"t":"inbox.item_updated","v":1,"ts":"2026-11-01T09:30:00Z","id":"c2",\
          "d":{"item_id":"\(Fixtures.itemId)","state_version":2,"changes":{"read":true}},\
          "counters":{"unseen":0,"unread":0,"total":1,"version":6}}
          """.utf8
        )
      )
    )
    await client.store.handle(stale)
    XCTAssertEqual(client.store.items.first?.read, false)
    let fresh = try XCTUnwrap(
      RelayRealtimeEnvelope(
        json: Data(
          """
          {"t":"inbox.item_updated","v":1,"ts":"2026-11-01T09:30:00Z","id":"c3",\
          "d":{"item_id":"\(Fixtures.itemId)","state_version":3,"changes":{"read":true,"seen":true}},\
          "counters":{"unseen":0,"unread":0,"total":1,"version":7}}
          """.utf8
        )
      )
    )
    await client.store.handle(fresh)
    XCTAssertEqual(client.store.items.first?.read, true)
    XCTAssertEqual(client.store.streamCursor, "c3")
    XCTAssertEqual(client.store.counters.version, 7)
    for _ in 0..<20 where delivered.removed.isEmpty { await Task.yield() }
    XCTAssertEqual(delivered.removed, ["n1"])
  }

  @MainActor
  func testIN29DeltaSyncFallsBackToColdSyncWhenTruncated() async {
    let harness = Harness()
    let client = harness.client()
    harness.transport.enqueue(
      "listMyInboxItems",
      .json(
        200,
        """
        {"object":"list","data":[],"has_more":false,"next_cursor":null,"previous_cursor":null,\
        "cursor":"c1"}
        """
      ),
      .json(
        200,
        """
        {"object":"list","data":[\(Fixtures.item())],"has_more":false,"next_cursor":null,\
        "previous_cursor":null,"cursor":"c9"}
        """
      )
    )
    harness.transport.enqueue(
      "listMyInboxChanges",
      .json(
        200,
        """
        {"object":"inbox_changes","changes":[],"cursor":"c5","has_more":false,"truncated":true,\
        "resync_required":false,"counters":\(Fixtures.counters(unseen: 1, unread: 1, version: 8))}
        """
      )
    )
    await client.store.synchronize()
    await client.store.synchronize()
    XCTAssertEqual(harness.transport.requests("listMyInboxChanges").first?.request.path?.contains("since=c1"), true)
    XCTAssertEqual(client.store.items.map(\.id), [Fixtures.itemId])
    XCTAssertEqual(client.store.streamCursor, "c9")
  }

  func testIN35ForegroundOrderAndBackgroundClose() async {
    let steps = RecordingSteps()
    let lifecycle = RelayLifecycle(steps: steps)
    await lifecycle.enterForeground()
    await lifecycle.enterForeground()
    await lifecycle.enterBackground()
    XCTAssertEqual(steps.values, ["counters", "connect", "sync", "drain", "disconnect"])
  }

  @MainActor
  func testIN35SyncSignalPushRunsADeltaSync() async {
    let harness = Harness()
    let client = harness.client()
    harness.transport.enqueue("getMyInboxCounters", .json(200, Fixtures.counters(unseen: 2, unread: 2, version: 3)))
    harness.transport.enqueue(
      "listMyInboxItems",
      .json(
        200,
        """
        {"object":"list","data":[],"has_more":false,"next_cursor":null,"previous_cursor":null,\
        "cursor":"c1"}
        """
      )
    )
    let handled = await client.handleBackgroundPush(userInfo: ["relay": ["sync": true, "counter_version": 3]])
    XCTAssertTrue(handled)
    XCTAssertEqual(client.store.counters.unseen, 2)
    let ignored = await client.handleBackgroundPush(userInfo: ["aps": ["alert": "x"]])
    XCTAssertFalse(ignored)
  }
}

final class RecordingSteps: RelayLifecycleSteps, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []

  var values: [String] {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  private func add(_ value: String) {
    lock.lock()
    defer { lock.unlock() }
    stored.append(value)
  }

  func refreshCounters() async { add("counters") }
  func connectRealtime() async { add("connect") }
  func synchronize() async { add("sync") }
  func drainQueue() async { add("drain") }
  func disconnectRealtime() async { add("disconnect") }
}
