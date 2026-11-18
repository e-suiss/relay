import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest

@testable import EsuissRelay

final class MockTransport: ClientTransport, @unchecked Sendable {
  struct Recorded {
    let request: HTTPRequest
    let body: Data
    let operationID: String

    var json: [String: Any] {
      (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }

    func header(_ name: String) -> String? {
      request.headerFields[HTTPField.Name(name)!]
    }
  }

  struct Reply {
    let status: Int
    let body: String
    let headers: [String: String]

    static func json(_ status: Int, _ body: String, headers: [String: String] = [:]) -> Reply {
      Reply(status: status, body: body, headers: headers)
    }

    static func problem(
      _ status: Int,
      code: String,
      retryable: Bool? = nil,
      extra: String = "",
      headers: [String: String] = [:]
    ) -> Reply {
      let retry = retryable.map { ",\"retryable\":\($0)" } ?? ""
      let body =
        "{\"type\":\"https://relay.test/v1/errors/\(code)\",\"title\":\"t\",\"status\":\(status),"
        + "\"code\":\"\(code)\"\(retry)\(extra)}"
      return Reply(status: status, body: body, headers: headers)
    }
  }

  private let lock = NSLock()
  private var queues: [String: [Reply]] = [:]
  private(set) var recorded: [Recorded] = []

  func enqueue(_ operationID: String, _ replies: Reply...) {
    lock.lock()
    defer { lock.unlock() }
    queues[operationID, default: []].append(contentsOf: replies)
  }

  func requests(_ operationID: String) -> [Recorded] {
    lock.lock()
    defer { lock.unlock() }
    return recorded.filter { $0.operationID == operationID }
  }

  var allRequests: [Recorded] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func send(
    _ request: HTTPRequest,
    body: HTTPBody?,
    baseURL: URL,
    operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    var data = Data()
    if let body { data = try await Data(collecting: body, upTo: 1 << 20) }
    let reply: Reply? = {
      lock.lock()
      defer { lock.unlock() }
      recorded.append(Recorded(request: request, body: data, operationID: operationID))
      guard var queue = queues[operationID], !queue.isEmpty else { return nil }
      let first = queue.removeFirst()
      queues[operationID] = queue
      return first
    }()
    guard let reply else { throw URLError(.notConnectedToInternet) }
    var fields = HTTPFields()
    fields[HTTPField.Name("Request-Id")!] = "req_test"
    fields[HTTPField.Name("Relay-Version")!] = "2026-11-01"
    fields[.contentType] = reply.status >= 400 ? "application/problem+json" : "application/json"
    for (name, value) in reply.headers { fields[HTTPField.Name(name)!] = value }
    return (
      HTTPResponse(status: .init(code: reply.status), headerFields: fields), HTTPBody(reply.body)
    )
  }
}

final class FakeClock: RelayClock, @unchecked Sendable {
  private let lock = NSLock()
  private var current = Date(timeIntervalSince1970: 1_800_000_000)
  private(set) var sleeps: [TimeInterval] = []

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  func sleep(seconds: TimeInterval) async throws {
    lock.lock()
    sleeps.append(seconds)
    current = current.addingTimeInterval(seconds)
    lock.unlock()
    await Task.yield()
  }

  var recordedSleeps: [TimeInterval] {
    lock.lock()
    defer { lock.unlock() }
    return sleeps
  }
}

struct FixedRandom: RelayRandom {
  var value: Double = 0.5

  func unit() -> Double { value }

  func uuid() -> UUID { UUID() }
}

final class StaticTokens: RelayTokenProvider, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var calls: [Bool] = []
  let scopes: Set<RelayScope>

  init(scopes: Set<RelayScope> = []) {
    self.scopes = scopes
  }

  func subscriberToken(forceRefresh: Bool) async throws -> RelaySubscriberToken {
    lock.lock()
    calls.append(forceRefresh)
    let count = calls.count
    lock.unlock()
    return RelaySubscriberToken(
      value: "subscriber-token-\(count)",
      expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
      scopes: scopes
    )
  }

  var refreshes: Int {
    lock.lock()
    defer { lock.unlock() }
    return calls.filter { $0 }.count
  }
}

final class CapturingLogger: RelayLogger, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var messages: [String] = []

  func log(_ level: RelayLogLevel, _ message: String) {
    lock.lock()
    defer { lock.unlock() }
    messages.append(message)
  }
}

struct FixedSettings: RelayNotificationSettingsReader {
  var settings = RelayNotificationSettings(permission: .granted)

  func read() async -> RelayNotificationSettings { settings }
}

final class FakeDelivered: RelayDeliveredNotificationCenter, @unchecked Sendable {
  private let lock = NSLock()
  var shown: [RelayDeliveredNotification]
  private(set) var removed: [String] = []

  init(_ shown: [RelayDeliveredNotification] = []) {
    self.shown = shown
  }

  func delivered() async -> [RelayDeliveredNotification] {
    lock.lock()
    defer { lock.unlock() }
    return shown
  }

  func remove(identifiers: [String]) async {
    lock.lock()
    defer { lock.unlock() }
    removed.append(contentsOf: identifiers)
  }
}

struct Harness {
  let transport = MockTransport()
  let clock = FakeClock()
  let tokens: StaticTokens
  let logger = CapturingLogger()
  let configuration: RelayConfiguration

  init(scopes: Set<RelayScope> = [], reportDisplayedNotifications: Bool = false) {
    tokens = StaticTokens(scopes: scopes)
    configuration = RelayConfiguration(
      baseURL: URL(string: "https://relay.test")!,
      appIdentifier: "app.suiss.example",
      tokenProvider: tokens,
      clock: clock,
      random: FixedRandom(),
      logger: logger,
      reportDisplayedNotifications: reportDisplayedNotifications
    )
  }

  var http: RelayHTTP { RelayHTTP(configuration: configuration, transport: transport) }

  @MainActor
  func client(
    devices: any RelayDeviceStorage = MemoryDeviceStorage(),
    settings: RelayNotificationSettings = RelayNotificationSettings(permission: .granted),
    delivered: any RelayDeliveredNotificationCenter = FakeDelivered(),
    realtime: [any RelayRealtimeTransport] = []
  ) -> RelayClient {
    RelayClient(
      configuration: configuration,
      transport: transport,
      realtimeTransports: realtime,
      deviceStorage: devices,
      queueStorage: MemoryIntentQueueStorage(),
      settings: FixedSettings(settings: settings),
      delivered: delivered
    )
  }
}

enum Fixtures {
  static let itemId = "inb_01j9zq3k4m5n6p7q8r9s0t1v2w"
  static let deviceId = "dev_01j9zq3k4m5n6p7q8r9s0t1v2w"
  static let deliveryId = "dlv_01j9zq3k4m5n6p7q8r9s0t1v2w"

  static func item(id: String = itemId, version: Int = 1, read: Bool = false) -> String {
    """
    {"object":"inbox_item","kind":"personal","id":"\(id)","state_version":\(version),"seen":\(read),\
    "read":\(read),"archived":false,"hidden":false,"expired":false,"snoozed_until":null,\
    "seen_at":null,"read_at":null,"archived_at":null,"created_at":"2026-11-01T09:30:00Z",\
    "last_activity_at":"2026-11-01T09:30:00.123456Z","category":"orders","tags":[],"severity":null,\
    "group_key":"order-1","title":"Order shipped","body":"Your order is on its way","avatar_url":null,\
    "url":"https://shop.test/orders/1","actions":[],"data":[],"locale":"en","dir":null,\
    "activity_count":1,"actor_count":0,"expires_at":null}
    """
  }

  static let waitpointId = "wp_01j9zq3k4m5n6p7q8r9s0t1v2w"
  static let digest = String(repeating: "ab", count: 32)

  static func item(id: String = itemId, version: Int = 1, extra: String) -> String {
    String(item(id: id, version: version).dropLast()) + ",\(extra)}"
  }

  static func waitpoint(
    kind: String = "response",
    status: String = "awaiting",
    approvalURL: String = "null"
  ) -> String {
    """
    "waitpoint":{"id":"\(waitpointId)","kind":"\(kind)","status":"\(status)",\
    "subject_digest":"\(digest)","options":[{"label":"Yes","value":"yes"},\
    {"label":"No","value":"no"}],"responder":null,"responded_at":null,\
    "approval_url":\(approvalURL)}
    """
  }

  static func list(_ items: String...) -> String {
    """
    {"object":"list","data":[\(items.joined(separator: ","))],"has_more":false,\
    "next_cursor":null,"previous_cursor":null,"cursor":"c1"}
    """
  }

  static func state(id: String = itemId, version: Int, read: Bool) -> String {
    """
    {"id":"\(id)","state_version":\(version),"seen":true,"read":\(read),"archived":false,\
    "hidden":false,"expired":false,"snoozed_until":null,"seen_at":null,"read_at":null,\
    "archived_at":null}
    """
  }

  static func counters(unseen: Int, unread: Int, version: Int) -> String {
    "{\"object\":\"inbox_counters\",\"unseen\":\(unseen),\"unread\":\(unread),\"total\":5,\"version\":\(version)}"
  }

  static func device(id: String = deviceId) -> String {
    """
    {"object":"device","id":"\(id)","subscriber_id":"sub_01j9zq3k4m5n6p7q8r9s0t1v2w","platform":"apns",\
    "app":"app.suiss.example","token_fingerprint":"0123456789abcdef","apns_environment":"production",\
    "permission":"granted","android_channels":[],"locale":"en-US","timezone":"Europe/Istanbul",\
    "state":"active","disabled_reason":null,"registered_at":"2026-11-01T09:30:00Z",\
    "last_seen_at":"2026-11-01T09:30:00Z","deleted_at":null,"created_at":"2026-11-01T09:30:00Z",\
    "updated_at":"2026-11-01T09:30:00Z"}
    """
  }

  static var repositoryRoot: URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }
}

final class Recorder: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []

  func append(_ value: String) {
    lock.lock()
    defer { lock.unlock() }
    stored.append(value)
  }

  var values: [String] {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
}
