import CryptoKit
import Foundation
import HTTPTypes

#if canImport(UIKit)
  import UIKit
#endif

// OP-54
// OP-95
/// One displayed notification waiting to be reported: the SHA-256 digest of its identifier and the
/// time it was shown. The identifier itself and the content never leave the device.
public struct RelayDisplayedNotification: Equatable, Sendable {
  public let digest: String
  public let displayedAt: Date

  public init(notificationId: String, displayedAt: Date) {
    self.digest = RelayDisplayedNotification.digest(of: notificationId)
    self.displayedAt = displayedAt
  }

  /// The lowercase hex SHA-256 of the identifier's UTF-8 bytes.
  public static func digest(of notificationId: String) -> String {
    SHA256.hash(data: Data(notificationId.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

/// What Relay counted for one reported batch.
public struct RelayDisplayedNotificationsResult: Equatable, Sendable {
  public let accepted: Int
  public let duplicates: Int

  public init(accepted: Int, duplicates: Int) {
    self.accepted = accepted
    self.duplicates = duplicates
  }
}

struct DisplayedNotificationBatch: Equatable, Sendable {
  let idempotencyKey: String
  let createdAt: Date
  let notifications: [RelayDisplayedNotification]
}

typealias DisplayedBatchSender = @Sendable (DisplayedNotificationBatch) async throws -> Void

typealias DisplayedFlushScheduler =
  @Sendable (TimeInterval, @escaping @Sendable () async -> Void) -> Void

// OP-54
// OP-95
/// Reports the digests of displayed notifications in batches when
/// `RelayConfiguration.reportDisplayedNotifications` is on; otherwise it does nothing. A batch is
/// sent at 20 waiting notifications, 30 seconds after the first one and when the app goes to the
/// background. A failed batch is sent again with the same idempotency key on the next flush and is
/// dropped after 24 hours. The same notification displayed twice is reported twice.
public actor RelayDisplayedNotificationReporter {
  static let flushCount = 20
  static let requestLimit = 100
  static let flushInterval: TimeInterval = 30
  static let maxAge: TimeInterval = 86_400

  public nonisolated let isEnabled: Bool
  private let send: DisplayedBatchSender
  private let schedule: DisplayedFlushScheduler
  private let clock: any RelayClock
  private let random: any RelayRandom
  private let logger: any RelayLogger
  private var queued: [RelayDisplayedNotification] = []
  private var batches: [DisplayedNotificationBatch] = []
  private var flushing = false
  private var timerArmed = false

  init(
    isEnabled: Bool,
    clock: any RelayClock,
    random: any RelayRandom,
    logger: any RelayLogger,
    schedule: @escaping DisplayedFlushScheduler = RelayDisplayedNotificationReporter.sleepThenFire,
    send: @escaping DisplayedBatchSender
  ) {
    self.isEnabled = isEnabled
    self.clock = clock
    self.random = random
    self.logger = logger
    self.schedule = schedule
    self.send = send
  }

  init(http: RelayHTTP) {
    let configuration = http.configuration
    self.init(
      isEnabled: configuration.reportDisplayedNotifications,
      clock: configuration.clock,
      random: configuration.random,
      logger: configuration.logger,
      send: { batch in
        _ = try await http.reportDisplayed(
          batch.notifications, idempotencyKey: batch.idempotencyKey)
      }
    )
  }

  /// Queues a notification the app displayed itself, by its Relay identifier.
  public func report(notificationId: String) async {
    guard isEnabled, !notificationId.isEmpty else { return }
    queued.append(
      RelayDisplayedNotification(notificationId: notificationId, displayedAt: clock.now()))
    if queued.count >= RelayDisplayedNotificationReporter.flushCount {
      await flush()
    } else {
      armTimer()
    }
  }

  /// Sends everything waiting now, for example when the app goes to the background.
  public func flush() async {
    guard isEnabled, !flushing else { return }
    flushing = true
    while true {
      seal()
      let now = clock.now()
      batches.removeAll {
        now.timeIntervalSince($0.createdAt) > RelayDisplayedNotificationReporter.maxAge
      }
      guard let batch = batches.first else { break }
      do {
        try await send(batch)
        batches.removeAll { $0.idempotencyKey == batch.idempotencyKey }
        logger.log(.debug, "displayed notifications reported")
      } catch {
        logger.log(.debug, "displayed notifications kept for the next flush")
        break
      }
    }
    flushing = false
    armTimer()
  }

  /// The notifications not yet sent, in the order they were displayed.
  public var pending: [RelayDisplayedNotification] {
    batches.flatMap(\.notifications) + queued
  }

  var waitingBatches: [DisplayedNotificationBatch] { batches }

  private func seal() {
    var start = 0
    while start < queued.count {
      let end = min(start + RelayDisplayedNotificationReporter.requestLimit, queued.count)
      batches.append(
        DisplayedNotificationBatch(
          idempotencyKey: IdempotencyKey.make(random),
          createdAt: queued[start].displayedAt,
          notifications: Array(queued[start..<end])
        )
      )
      start = end
    }
    queued.removeAll()
  }

  private func armTimer() {
    guard !timerArmed, !queued.isEmpty || !batches.isEmpty else { return }
    timerArmed = true
    schedule(RelayDisplayedNotificationReporter.flushInterval) { [weak self] in
      await self?.timerFired()
    }
  }

  private func timerFired() async {
    timerArmed = false
    await flush()
  }

  static let sleepThenFire: DisplayedFlushScheduler = { seconds, fire in
    Task {
      try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      await fire()
    }
  }
}

final class DisplayedNotificationBackgroundObserver: @unchecked Sendable {
  private let center: NotificationCenter
  private var token: NSObjectProtocol?

  init(reporter: RelayDisplayedNotificationReporter, center: NotificationCenter = .default) {
    self.center = center
    guard reporter.isEnabled else { return }
    #if canImport(UIKit) && !os(watchOS)
      token = center.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: nil
      ) { _ in
        Task { await reporter.flush() }
      }
    #endif
  }

  deinit {
    if let token { center.removeObserver(token) }
  }
}

private struct DisplayedNotificationsBody: Encodable {
  struct Entry: Encodable {
    let digest: String
    let displayedAt: String

    enum CodingKeys: String, CodingKey {
      case digest
      case displayedAt = "displayed_at"
    }
  }

  let notifications: [Entry]
}

private struct DisplayedNotificationsResponse: Decodable {
  let accepted: Int
  let duplicates: Int
}

extension RelayHTTP {
  // OP-95
  func reportDisplayed(
    _ notifications: [RelayDisplayedNotification],
    idempotencyKey: String
  ) async throws -> RelayDisplayedNotificationsResult {
    let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    let body = DisplayedNotificationsBody(
      notifications: notifications.map {
        DisplayedNotificationsBody.Entry(
          digest: $0.digest,
          displayedAt: format.format($0.displayedAt)
        )
      }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = try encoder.encode(body)
    return try await perform(scope: .devicesWrite) { _ in
      let (response, data) = try await self.send(
        .post,
        path: "/v1/subscriber/displayed_notifications",
        json: json,
        idempotencyKey: idempotencyKey,
        operationID: "reportMyDisplayedNotifications"
      )
      guard response.status.code == 202,
        let decoded = try? JSONDecoder().decode(DisplayedNotificationsResponse.self, from: data)
      else { throw RelayError.invalidResponse("reportMyDisplayedNotifications") }
      return RelayDisplayedNotificationsResult(
        accepted: decoded.accepted,
        duplicates: decoded.duplicates
      )
    }
  }
}
