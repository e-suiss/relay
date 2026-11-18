import Foundation
import HTTPTypes
import XCTest

@testable import EsuissRelay

final class ManualScheduler: @unchecked Sendable {
  private let lock = NSLock()
  private var callbacks: [@Sendable () async -> Void] = []
  private var delays: [TimeInterval] = []

  func schedule(_ seconds: TimeInterval, _ fire: @escaping @Sendable () async -> Void) {
    lock.lock()
    defer { lock.unlock() }
    delays.append(seconds)
    callbacks.append(fire)
  }

  var requested: [TimeInterval] {
    lock.lock()
    defer { lock.unlock() }
    return delays
  }

  func fire() async {
    let due = take()
    for callback in due { await callback() }
  }

  private func take() -> [@Sendable () async -> Void] {
    lock.lock()
    defer { lock.unlock() }
    let due = callbacks
    callbacks = []
    return due
  }
}

final class BatchRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [DisplayedNotificationBatch] = []
  private var failures: Int
  private var holdFirst: Bool
  private var gate: CheckedContinuation<Void, Never>?

  init(failures: Int = 0, holdFirst: Bool = false) {
    self.failures = failures
    self.holdFirst = holdFirst
  }

  func send(_ batch: DisplayedNotificationBatch) async throws {
    if takeHold() {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        lock.lock()
        stored.append(batch)
        gate = continuation
        lock.unlock()
      }
      return
    }
    if record(batch) { throw RelayError.transport("offline") }
  }

  func release() {
    lock.lock()
    let waiting = gate
    gate = nil
    lock.unlock()
    waiting?.resume()
  }

  var batches: [DisplayedNotificationBatch] {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  private func takeHold() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let hold = holdFirst
    holdFirst = false
    return hold
  }

  private func record(_ batch: DisplayedNotificationBatch) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    stored.append(batch)
    guard failures > 0 else { return false }
    failures -= 1
    return true
  }
}

final class DisplayedNotificationsTests: XCTestCase {
  static let notificationId = "ntf_01j9zq3k4m5n6p7q8r9s0t1v2w"

  func makeReporter(
    _ harness: Harness,
    enabled: Bool = true,
    scheduler: ManualScheduler = ManualScheduler(),
    recorder: BatchRecorder = BatchRecorder()
  ) -> RelayDisplayedNotificationReporter {
    RelayDisplayedNotificationReporter(
      isEnabled: enabled,
      clock: harness.clock,
      random: SystemRandom(),
      logger: harness.logger,
      schedule: { seconds, fire in scheduler.schedule(seconds, fire) },
      send: { batch in try await recorder.send(batch) }
    )
  }

  func testOP95DigestIsTheLowercaseHexSHA256OfTheIdentifier() {
    XCTAssertEqual(
      RelayDisplayedNotification.digest(of: "abc"),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
    let digest = RelayDisplayedNotification.digest(of: Self.notificationId)
    XCTAssertEqual(digest.count, 64)
    XCTAssertNil(digest.range(of: "[^0-9a-f]", options: .regularExpression))
  }

  func testOP95ReportingIsOffByDefault() async {
    let harness = Harness()
    XCTAssertFalse(harness.configuration.reportDisplayedNotifications)
    let scheduler = ManualScheduler()
    let recorder = BatchRecorder()
    let reporter = makeReporter(harness, enabled: false, scheduler: scheduler, recorder: recorder)
    for _ in 0..<25 { await reporter.report(notificationId: Self.notificationId) }
    await reporter.flush()
    let pending = await reporter.pending
    XCTAssertTrue(pending.isEmpty)
    XCTAssertTrue(recorder.batches.isEmpty)
    XCTAssertTrue(scheduler.requested.isEmpty)
  }

  func testOP95TwentyDisplaysAreSentAtOnceAndRepeatsStayRepeats() async {
    let harness = Harness()
    let recorder = BatchRecorder()
    let reporter = makeReporter(harness, recorder: recorder)
    for _ in 0..<19 { await reporter.report(notificationId: Self.notificationId) }
    XCTAssertTrue(recorder.batches.isEmpty)
    await reporter.report(notificationId: Self.notificationId)
    XCTAssertEqual(recorder.batches.count, 1)
    let batch = recorder.batches[0]
    XCTAssertEqual(batch.notifications.count, 20)
    XCTAssertEqual(
      Set(batch.notifications.map(\.digest)),
      [RelayDisplayedNotification.digest(of: Self.notificationId)]
    )
    XCTAssertEqual(batch.notifications[0].displayedAt, harness.clock.now())
    let pending = await reporter.pending
    XCTAssertTrue(pending.isEmpty)
  }

  func testOP95WaitingDisplaysAreSentThirtySecondsLater() async {
    let harness = Harness()
    let scheduler = ManualScheduler()
    let recorder = BatchRecorder()
    let reporter = makeReporter(harness, scheduler: scheduler, recorder: recorder)
    await reporter.report(notificationId: Self.notificationId)
    await reporter.report(notificationId: "inb_01j9zq3k4m5n6p7q8r9s0t1v2w")
    XCTAssertEqual(scheduler.requested, [30])
    XCTAssertTrue(recorder.batches.isEmpty)
    await scheduler.fire()
    XCTAssertEqual(recorder.batches.count, 1)
    XCTAssertEqual(recorder.batches[0].notifications.count, 2)
    await scheduler.fire()
    XCTAssertEqual(recorder.batches.count, 1)
  }

  func testOP95AFailedBatchKeepsItsIdempotencyKeyUntilItIsSent() async {
    let harness = Harness()
    let scheduler = ManualScheduler()
    let recorder = BatchRecorder(failures: 1)
    let reporter = makeReporter(harness, scheduler: scheduler, recorder: recorder)
    await reporter.report(notificationId: Self.notificationId)
    await reporter.flush()
    let kept = await reporter.pending
    XCTAssertEqual(kept.count, 1)
    XCTAssertEqual(scheduler.requested, [30])
    await reporter.report(notificationId: Self.notificationId)
    await scheduler.fire()
    let batches = recorder.batches
    XCTAssertEqual(batches.count, 3)
    XCTAssertEqual(batches[0].idempotencyKey, batches[1].idempotencyKey)
    XCTAssertNotEqual(batches[1].idempotencyKey, batches[2].idempotencyKey)
    XCTAssertTrue(batches[0].idempotencyKey.hasPrefix("rly-"))
    let pending = await reporter.pending
    XCTAssertTrue(pending.isEmpty)
  }

  func testOP95BatchesOlderThanADayAreDropped() async throws {
    let harness = Harness()
    let recorder = BatchRecorder(failures: 1)
    let reporter = makeReporter(harness, recorder: recorder)
    await reporter.report(notificationId: Self.notificationId)
    await reporter.flush()
    try await harness.clock.sleep(seconds: 86_401)
    await reporter.flush()
    XCTAssertEqual(recorder.batches.count, 1)
    let pending = await reporter.pending
    XCTAssertTrue(pending.isEmpty)
  }

  func testOP95ARequestCarriesAtMostOneHundred() async {
    let harness = Harness()
    let recorder = BatchRecorder(holdFirst: true)
    let reporter = makeReporter(harness, recorder: recorder)
    let first = Task {
      for _ in 0..<20 { await reporter.report(notificationId: Self.notificationId) }
    }
    while recorder.batches.isEmpty { await Task.yield() }
    for _ in 0..<230 { await reporter.report(notificationId: Self.notificationId) }
    recorder.release()
    await first.value
    XCTAssertEqual(recorder.batches.map(\.notifications.count), [20, 100, 100, 30])
  }

  func testOP95RequestSendsOnlyDigestsWithAnIdempotencyKey() async throws {
    let harness = Harness(scopes: [.devicesWrite])
    harness.transport.enqueue(
      "reportMyDisplayedNotifications",
      .problem(503, code: "service_unavailable", retryable: true),
      .json(202, "{\"object\":\"displayed_notifications\",\"accepted\":2,\"duplicates\":1}")
    )
    let shown = RelayDisplayedNotification(
      notificationId: Self.notificationId, displayedAt: harness.clock.now())
    let result = try await harness.http.reportDisplayed(
      [shown, shown], idempotencyKey: "rly-test")
    XCTAssertEqual(result, RelayDisplayedNotificationsResult(accepted: 2, duplicates: 1))
    let requests = harness.transport.requests("reportMyDisplayedNotifications")
    XCTAssertEqual(requests.count, 2)
    let request = requests[1]
    XCTAssertEqual(request.request.method, .post)
    XCTAssertEqual(request.request.path, "/v1/subscriber/displayed_notifications")
    XCTAssertEqual(request.header("Idempotency-Key"), "rly-test")
    XCTAssertEqual(requests[0].header("Idempotency-Key"), "rly-test")
    XCTAssertEqual(request.header("Authorization"), "Bearer subscriber-token-1")
    XCTAssertEqual(request.header("Relay-Version"), "2026-11-01")
    XCTAssertEqual(request.header("Content-Type"), "application/json")
    let notifications = try XCTUnwrap(request.json["notifications"] as? [[String: Any]])
    XCTAssertEqual(notifications.count, 2)
    XCTAssertEqual(notifications[0]["digest"] as? String, shown.digest)
    let displayedAt = try XCTUnwrap(notifications[0]["displayed_at"] as? String)
    XCTAssertTrue(displayedAt.hasSuffix("Z"))
    XCTAssertEqual(try RelayDateTranscoder().decode(displayedAt), harness.clock.now())
    XCTAssertFalse(String(decoding: request.body, as: UTF8.self).contains(Self.notificationId))
  }

  func testOP95RequestNeedsTheDevicesScope() async {
    let harness = Harness(scopes: [.inboxRead])
    do {
      _ = try await harness.http.reportDisplayed([], idempotencyKey: "rly-test")
      XCTFail("expected missingScope")
    } catch {
      XCTAssertEqual(error as? RelayError, .missingScope(.devicesWrite))
    }
  }

  @MainActor
  func testOP95ForegroundPushesAndAppReportsReachRelay() async throws {
    let harness = Harness(reportDisplayedNotifications: true)
    let client = harness.client()
    XCTAssertTrue(client.displayedNotifications.isEnabled)
    await client.handleNotificationDisplayed(userInfo: ["relay": ["id": Fixtures.itemId]])
    await client.handleNotificationDisplayed(userInfo: ["relay": ["sync": true]])
    await client.reportDisplayed(notificationId: Self.notificationId)
    await client.displayedNotifications.flush()
    let failed = harness.transport.requests("reportMyDisplayedNotifications")
    XCTAssertFalse(failed.isEmpty)
    let pending = await client.displayedNotifications.pending
    XCTAssertEqual(
      pending.map(\.digest),
      [
        RelayDisplayedNotification.digest(of: Fixtures.itemId),
        RelayDisplayedNotification.digest(of: Self.notificationId),
      ]
    )
    harness.transport.enqueue(
      "reportMyDisplayedNotifications",
      .json(202, "{\"object\":\"displayed_notifications\",\"accepted\":2,\"duplicates\":0}")
    )
    await client.displayedNotifications.flush()
    let requests = harness.transport.requests("reportMyDisplayedNotifications")
    XCTAssertEqual(
      requests.last?.header("Idempotency-Key"), failed.first?.header("Idempotency-Key"))
    let flushed = await client.displayedNotifications.pending
    XCTAssertTrue(flushed.isEmpty)
  }

  @MainActor
  func testOP95ForegroundPushesAreNotReportedWhenTheOptionIsOff() async {
    let harness = Harness()
    let client = harness.client()
    XCTAssertFalse(client.displayedNotifications.isEnabled)
    await client.handleNotificationDisplayed(userInfo: ["relay": ["id": Fixtures.itemId]])
    await client.reportDisplayed(notificationId: Self.notificationId)
    await client.displayedNotifications.flush()
    let pending = await client.displayedNotifications.pending
    XCTAssertTrue(pending.isEmpty)
    XCTAssertTrue(harness.transport.requests("reportMyDisplayedNotifications").isEmpty)
  }
}
