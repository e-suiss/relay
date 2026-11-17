import Foundation
import XCTest

@testable import EsuissRelay

final class HTTPTests: XCTestCase {
  func testX29RetryKeepsTheIdempotencyKeyAndHonoursRetryAfter() async throws {
    let harness = Harness()
    harness.transport.enqueue(
      "markAllMyInboxRead",
      .problem(503, code: "service_unavailable", retryable: true, headers: ["Retry-After": "7"]),
      .json(
        200,
        """
        {"object":"inbox_read_all_result","scope":"all","category":null,"updated":2,\
        "cut_off":"2026-11-01T09:30:00Z","counters":\(Fixtures.counters(unseen: 0, unread: 0, version: 9))}
        """
      )
    )
    let counters = try await RelayInboxAPI(http: harness.http).markAllRead()
    XCTAssertEqual(counters.version, 9)
    let requests = harness.transport.requests("markAllMyInboxRead")
    XCTAssertEqual(requests.count, 2)
    XCTAssertNotNil(requests[0].header("Idempotency-Key"))
    XCTAssertEqual(requests[0].header("Idempotency-Key"), requests[1].header("Idempotency-Key"))
    XCTAssertEqual(requests[0].header("Relay-Version"), "2026-11-01")
    XCTAssertEqual(requests[0].header("Authorization"), "Bearer subscriber-token-1")
    XCTAssertGreaterThanOrEqual(harness.clock.recordedSleeps.first ?? 0, 7)
  }

  func testX29NonRetryableProblemIsThrownWithoutRetry() async {
    let harness = Harness()
    harness.transport.enqueue(
      "markAllMyInboxRead",
      .problem(422, code: "validation_failed", retryable: false)
    )
    do {
      _ = try await RelayInboxAPI(http: harness.http).markAllRead()
      XCTFail("expected a problem")
    } catch let error as RelayError {
      XCTAssertEqual(error.code, "validation_failed")
      XCTAssertFalse(error.isRetryable)
    } catch {
      XCTFail("unexpected \(error)")
    }
    XCTAssertEqual(harness.transport.requests("markAllMyInboxRead").count, 1)
    XCTAssertTrue(harness.clock.recordedSleeps.isEmpty)
  }

  func testX29ExpiredTokenIsRefreshedOnce() async throws {
    let harness = Harness()
    harness.transport.enqueue(
      "getMyInboxCounters",
      .problem(401, code: "auth_expired_token", retryable: false),
      .json(200, Fixtures.counters(unseen: 1, unread: 2, version: 3))
    )
    let counters = try await RelayInboxAPI(http: harness.http).counters()
    XCTAssertEqual(counters.unread, 2)
    XCTAssertEqual(harness.tokens.refreshes, 1)
    let requests = harness.transport.requests("getMyInboxCounters")
    XCTAssertEqual(requests.last?.header("Authorization"), "Bearer subscriber-token-2")
  }

  func testX29StatusDefaultsMatchTheErrorCatalog() throws {
    let url = Fixtures.repositoryRoot.appendingPathComponent("contracts/errors.yaml")
    let text = try String(contentsOf: url, encoding: .utf8)
    let defaults = ErrorCatalog.retryableDefaults(text)
    XCTAssertFalse(defaults.isEmpty)
    for entry in defaults {
      XCTAssertEqual(
        RetryClassifier.defaultRetryable(status: entry.status, code: entry.code),
        entry.retryable,
        "status \(entry.status) code \(entry.code ?? "-")"
      )
    }
    for entry in ErrorCatalog.codes(text) {
      XCTAssertEqual(
        RetryClassifier.isRetryable(status: entry.status, code: entry.code, declared: entry.retryable),
        entry.retryable
      )
    }
  }

  func testX31MissingScopeSendsNothing() async {
    let harness = Harness(scopes: [.inboxRead])
    do {
      _ = try await RelayInboxAPI(http: harness.http).markAllRead()
      XCTFail("expected missing scope")
    } catch let error as RelayError {
      XCTAssertEqual(error, .missingScope(.inboxWrite))
    } catch {
      XCTFail("unexpected \(error)")
    }
    XCTAssertTrue(harness.transport.allRequests.isEmpty)
  }

  func testX31TokenIsNeverPrinted() {
    let token = RelaySubscriberToken(value: "secret-value", expiresAt: Date())
    XCTAssertFalse(String(describing: token).contains("secret-value"))
    XCTAssertFalse(String(reflecting: token).contains("secret-value"))
  }

  func testX31GeneratedSurfaceHoldsOnlySubscriberOperations() throws {
    let url = Fixtures.repositoryRoot.appendingPathComponent(
      "sdks/swift/Generator/openapi-generator-config.yaml"
    )
    let text = try String(contentsOf: url, encoding: .utf8)
    let operations = text.split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { $0.hasPrefix("- ") && !$0.hasPrefix("- types") && !$0.hasPrefix("- client") }
      .map { String($0.dropFirst(2)) }
    XCTAssertFalse(operations.isEmpty)
    for operation in operations {
      XCTAssertTrue(operation.contains("My") || operation.hasPrefix("pollRealtime"), operation)
    }
    XCTAssertFalse(operations.contains("exchangeSubscriberToken"))
  }

  func testIN34BackoffIsFullJitterBetweenOneAndSixtySeconds() {
    let backoff = FullJitterBackoff(base: 1, cap: 60)
    XCTAssertEqual(backoff.ceiling(attempt: 0), 1)
    XCTAssertEqual(backoff.ceiling(attempt: 3), 8)
    XCTAssertEqual(backoff.ceiling(attempt: 10), 60)
    XCTAssertEqual(backoff.delay(attempt: 3, random: FixedRandom(value: 0.25)), 2)
    XCTAssertEqual(backoff.delay(attempt: 0, random: FixedRandom(value: 0)), 0)
    XCTAssertEqual(backoff.delay(attempt: 0, random: FixedRandom(value: 0.5), retryAfter: 4), 4)
  }
}

enum ErrorCatalog {
  struct Entry {
    let status: Int
    let code: String?
    let retryable: Bool
  }

  static func retryableDefaults(_ text: String) -> [Entry] {
    guard let start = text.range(of: "retryable_defaults:\n"),
      let end = text.range(of: "\ncodes:\n")
    else { return [] }
    return entries(String(text[start.upperBound..<end.lowerBound]), marker: "  - status:")
  }

  static func codes(_ text: String) -> [Entry] {
    guard let start = text.range(of: "\ncodes:\n") else { return [] }
    var result: [Entry] = []
    var code: String?
    var status: Int?
    for line in text[start.upperBound...].split(separator: "\n") {
      if line.hasPrefix("  - code: ") {
        code = String(line.dropFirst("  - code: ".count))
        status = nil
      } else if line.hasPrefix("    status: ") {
        status = Int(line.dropFirst("    status: ".count))
      } else if line.hasPrefix("    retryable: "), let currentCode = code, let currentStatus = status {
        result.append(
          Entry(status: currentStatus, code: currentCode, retryable: line.hasSuffix("true"))
        )
        code = nil
      }
    }
    return result
  }

  private static func entries(_ block: String, marker: String) -> [Entry] {
    var result: [Entry] = []
    var status: Int?
    var code: String?
    for line in block.split(separator: "\n") {
      if line.hasPrefix(marker) {
        status = Int(line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces))
        code = nil
      } else if line.hasPrefix("    code: ") {
        code = String(line.dropFirst("    code: ".count))
      } else if line.hasPrefix("    retryable: "), let currentStatus = status {
        result.append(Entry(status: currentStatus, code: code, retryable: line.hasSuffix("true")))
      }
    }
    return result
  }
}
