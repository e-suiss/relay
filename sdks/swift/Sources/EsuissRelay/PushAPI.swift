import EsuissRelayAPI
import Foundation
import OpenAPIRuntime

/// What the SDK remembers about this device's registration; the push token is not a secret.
public struct RelayDeviceRecord: Codable, Equatable, Sendable {
  public var deviceId: String
  public var token: String
}

/// Where the device registration survives app restarts (an App Group suite lets the Notification
/// Service Extension read it).
public protocol RelayDeviceStorage: Sendable {
  func load() -> RelayDeviceRecord?
  func save(_ record: RelayDeviceRecord?)
}

/// Keeps the registration in `UserDefaults`.
public final class UserDefaultsDeviceStorage: RelayDeviceStorage, @unchecked Sendable {
  private let defaults: UserDefaults
  private let key = "app.suiss.relay.device"

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func load() -> RelayDeviceRecord? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(RelayDeviceRecord.self, from: data)
  }

  public func save(_ record: RelayDeviceRecord?) {
    guard let record, let data = try? JSONEncoder().encode(record) else {
      defaults.removeObject(forKey: key)
      return
    }
    defaults.set(data, forKey: key)
  }
}

/// Keeps the registration in memory only.
public final class MemoryDeviceStorage: RelayDeviceStorage, @unchecked Sendable {
  private let lock = NSLock()
  private var record: RelayDeviceRecord?

  public init(_ record: RelayDeviceRecord? = nil) {
    self.record = record
  }

  public func load() -> RelayDeviceRecord? {
    lock.lock()
    defer { lock.unlock() }
    return record
  }

  public func save(_ record: RelayDeviceRecord?) {
    lock.lock()
    defer { lock.unlock() }
    self.record = record
  }
}

/// The APNs environment a device token was issued for.
public enum RelayApnsEnvironment: String, Sendable {
  case production
  case sandbox
}

/// A push receipt of the SDK; it is evidence beside the provider's acceptance (CH-32, DS-13).
public enum RelayReceipt: String, Sendable {
  case displayed
  case clicked
}

/// A device status signal of the versioned dictionary (IN-47).
public enum RelayDeviceSignal: String, Sendable, CaseIterable {
  case worn
  case locked
  case headphones
  case focus
  case breakPoint = "break"
}

// X-31
/// Push device registration, receipts and device status for the token's own subscriber (scope
/// `devices:write` and `presence:write`). It never writes the subscriber profile or consents.
public final class RelayPushAPI: Sendable {
  let http: RelayHTTP
  let storage: any RelayDeviceStorage
  let settings: any RelayNotificationSettingsReader

  init(
    http: RelayHTTP,
    storage: any RelayDeviceStorage,
    settings: any RelayNotificationSettingsReader
  ) {
    self.http = http
    self.storage = storage
    self.settings = settings
  }

  /// The registered device, when there is one.
  public var device: RelayDeviceRecord? { storage.load() }

  // CH-28
  // CH-31
  // CH-65
  /// Registers or refreshes the APNs token with the current permission and the interruption
  /// permissions the device knows; call it on every app start and whenever the token changes. A
  /// changed token names the token it replaces.
  @discardableResult
  public func register(apnsToken: Data, environment: RelayApnsEnvironment) async throws -> String {
    let token = apnsToken.map { String(format: "%02x", $0) }.joined()
    return try await register(token: token, environment: environment)
  }

  @discardableResult
  public func register(token: String, environment: RelayApnsEnvironment) async throws -> String {
    let current = await settings.read()
    let previous = storage.load()
    let registration = Components.Schemas.DeviceRegistration(
      apnsEnvironment: environment == .sandbox ? .sandbox : .production,
      app: http.configuration.appIdentifier,
      interruptionPermissions: RelayPushAPI.wire(current.interruptionPermissions),
      locale: RelayDeviceContext.locale(),
      permission: Components.Schemas.DevicePermission(rawValue: current.permission.rawValue)
        ?? .notDetermined,
      platform: .apns,
      previousToken: previous.flatMap { $0.token == token ? nil : $0.token },
      timezone: RelayDeviceContext.timeZone(),
      token: token
    )
    let key = IdempotencyKey.make(http.configuration.random)
    let deviceId = try await http.perform(scope: .devicesWrite) { client in
      let output = try await client.registerMyDevice(
        .init(headers: .init(idempotencyKey: key), body: .json(registration))
      )
      switch output {
      case .ok(let ok):
        return try ok.body.json.id
      case .created(let created):
        return try created.body.json.id
      default:
        throw RelayError.invalidResponse("registerMyDevice")
      }
    }
    storage.save(RelayDeviceRecord(deviceId: deviceId, token: token))
    http.configuration.logger.log(.info, "push device registered")
    return deviceId
  }

  /// Sends the stored token again with the current permission (every app start, CH-28).
  public func refreshRegistration(environment: RelayApnsEnvironment) async throws {
    guard let record = storage.load() else { return }
    try await register(token: record.token, environment: environment)
  }

  /// Disables this device on logout; preferences stay (CH-31, PC-16).
  public func unregister() async throws {
    guard let record = storage.load() else { return }
    let key = IdempotencyKey.make(http.configuration.random)
    do {
      try await http.perform(scope: .devicesWrite) { client in
        let output = try await client.deleteMyDevice(
          .init(path: .init(deviceId: record.deviceId), headers: .init(idempotencyKey: key))
        )
        guard case .ok = output else { throw RelayError.invalidResponse("deleteMyDevice") }
      }
    } catch let error as RelayError {
      if case .problem(let problem, _) = error, problem.status == 404 {
        storage.save(nil)
        return
      }
      throw error
    }
    storage.save(nil)
  }

  // CH-32
  /// Records that a push was displayed or clicked.
  public func record(_ receipt: RelayReceipt, deliveryId: String) async throws {
    let key = IdempotencyKey.make(http.configuration.random)
    let now = http.configuration.clock.now()
    try await http.perform(scope: .devicesWrite) { client in
      let output = try await client.recordMyPushReceipt(
        .init(
          headers: .init(idempotencyKey: key),
          body: .json(
            .init(
              deliveryId: deliveryId,
              occurredAt: now,
              receipt: receipt == .clicked ? .clicked : .displayed
            )
          )
        )
      )
      guard case .accepted = output else {
        throw RelayError.invalidResponse("recordMyPushReceipt")
      }
    }
  }

  // IN-47
  // IN-48
  /// Writes the changed status signals of this device with a time to live. The values are personal
  /// data: they are never logged and never kept by the SDK.
  public func updateStatus(_ signals: [RelayDeviceSignal: Bool], ttl: TimeInterval = 300)
    async throws
  {
    guard !signals.isEmpty else { return }
    guard let record = storage.load() else { throw RelayError.notRegistered }
    let seconds = Int(min(max(ttl.rounded(), 1), 900))
    var payload = Components.Schemas.DeviceStatusWrite.SignalsPayload()
    for (signal, value) in signals {
      let container = try OpenAPIValueContainer(unvalidatedValue: value)
      switch signal {
      case .worn: payload.worn = container
      case .locked: payload.locked = container
      case .headphones: payload.headphones = container
      case .focus: payload.focus = container
      case .breakPoint: payload._break = container
      }
    }
    let body = Components.Schemas.DeviceStatusWrite(
      signals: payload,
      ttl: "PT\(seconds)S",
      version: .v1
    )
    try await http.perform(scope: .presenceWrite) { client in
      let output = try await client.updateMyDeviceStatus(
        .init(path: .init(deviceId: record.deviceId), body: .json(body))
      )
      guard case .ok = output else { throw RelayError.invalidResponse("updateMyDeviceStatus") }
    }
    http.configuration.logger.log(.debug, "device status written")
  }

  // CH-33
  /// Fetches the content of a content-free push over TLS by the delivery id it carries (`relay_id`).
  /// `nil` means the generic text stays: no network, no time left, no permission, an unknown
  /// delivery or an identifier that does not name a delivery.
  public func content(for payload: RelayPushPayload) async -> RelayPushContent? {
    guard let deliveryId = payload.deliveryId else { return nil }
    return try? await content(deliveryId: deliveryId)
  }

  // CH-33
  /// Fetches the rendered content of one of the subscriber's push deliveries (scope `inbox:read`).
  public func content(deliveryId: String) async throws -> RelayPushContent {
    try await http.perform(scope: .inboxRead) { client in
      let output = try await client.getMyPushContent(.init(path: .init(deliveryId: deliveryId)))
      guard case .ok(let ok) = output else { throw RelayError.invalidResponse("getMyPushContent") }
      return RelayPushContent(try ok.body.json)
    }
  }

  // CH-65
  static func wire(_ permissions: RelayInterruptionPermissions)
    -> Components.Schemas.DeviceInterruptionPermissions?
  {
    guard !permissions.isEmpty else { return nil }
    return Components.Schemas.DeviceInterruptionPermissions(
      criticalAlerts: permissions.criticalAlerts.flatMap {
        Components.Schemas.DeviceInterruptionPermission(rawValue: $0.rawValue)
      },
      timeSensitive: permissions.timeSensitive.flatMap {
        Components.Schemas.DeviceInterruptionPermission(rawValue: $0.rawValue)
      }
    )
  }
}

// CH-33
/// The rendered content of a content-free push, as it was sent; it is never rendered again.
public struct RelayPushContent: Equatable, Sendable {
  public let deliveryId: String
  public let notificationId: String
  public let channel: String
  public let locale: String?
  public let title: String?
  public let subtitle: String?
  public let body: String?
  public let url: URL?

  public init(
    deliveryId: String,
    notificationId: String,
    channel: String = "push",
    locale: String? = nil,
    title: String? = nil,
    subtitle: String? = nil,
    body: String? = nil,
    url: URL? = nil
  ) {
    self.deliveryId = deliveryId
    self.notificationId = notificationId
    self.channel = channel
    self.locale = locale
    self.title = title
    self.subtitle = subtitle
    self.body = body
    self.url = url
  }

  /// Whether there is a text to show instead of the generic text.
  public var hasText: Bool { title != nil || body != nil }
}

extension RelayPushContent {
  init(_ content: Components.Schemas.PushContent) {
    let fields = content.content.value
    func text(_ key: String) -> String? {
      guard let value = fields[key].flatMap({ $0 }) as? String, !value.isEmpty else { return nil }
      return value
    }
    self.init(
      deliveryId: content.deliveryId,
      notificationId: content.notificationId,
      channel: content.channel.rawValue,
      locale: content.locale,
      title: text("title"),
      subtitle: text("subtitle"),
      body: text("body"),
      url: text("url").flatMap(URL.init(string:))
    )
  }
}

/// The locale and time zone a device reports with its registration.
enum RelayDeviceContext {
  static func locale(_ locale: Locale = .current) -> String? {
    let tag = locale.identifier(.bcp47)
    guard tag.range(of: "^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil,
      tag.count <= 35
    else { return nil }
    return tag
  }

  static func timeZone(_ zone: TimeZone = .current) -> String? {
    let identifier = zone.identifier
    let rejected =
      identifier == "GMT" || identifier == "UTC" || identifier.hasPrefix("Etc/")
      || identifier.hasPrefix("GMT")
    guard !rejected,
      identifier.range(of: "^[A-Za-z]+(/[A-Za-z0-9_+-]+)*$", options: .regularExpression) != nil
    else { return nil }
    return identifier
  }
}
