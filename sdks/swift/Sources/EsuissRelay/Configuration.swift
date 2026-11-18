import Foundation

// X-31
/// A narrow-scope Relay subscriber token. The host app obtains it (Access token exchange on its own
/// side) and hands it to the SDK; the SDK never holds Access tokens, API keys or other secrets.
public struct RelaySubscriberToken: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let value: String
  public let expiresAt: Date
  public let scopes: Set<RelayScope>

  public init(value: String, expiresAt: Date, scopes: Set<RelayScope> = []) {
    self.value = value
    self.expiresAt = expiresAt
    self.scopes = scopes
  }

  public var description: String { "RelaySubscriberToken(redacted)" }
  public var debugDescription: String { description }

  func allows(_ scope: RelayScope) -> Bool {
    scopes.isEmpty || scopes.contains(scope)
  }
}

/// The subscriber token scopes of the subscriber API.
public enum RelayScope: String, Sendable, CaseIterable {
  case inboxRead = "inbox:read"
  case inboxWrite = "inbox:write"
  case preferences
  case devicesWrite = "devices:write"
  case presenceWrite = "presence:write"
  case aguiRead = "agui:read"
}

// X-31
/// Supplies subscriber tokens. `forceRefresh` asks for a new token after Relay refused the current one.
public protocol RelayTokenProvider: Sendable {
  func subscriberToken(forceRefresh: Bool) async throws -> RelaySubscriberToken
}

/// Settings of a Relay client.
public struct RelayConfiguration: Sendable {
  /// The dated API version this SDK release is pinned to (X-48).
  public static let apiVersion = "2026-11-01"

  public var baseURL: URL
  public var appIdentifier: String
  public var tokenProvider: any RelayTokenProvider
  public var clock: any RelayClock
  public var random: any RelayRandom
  public var logger: any RelayLogger
  public var maxRetries: Int
  public var storageDirectory: URL?

  public init(
    baseURL: URL,
    appIdentifier: String,
    tokenProvider: any RelayTokenProvider,
    clock: any RelayClock = SystemClock(),
    random: any RelayRandom = SystemRandom(),
    logger: any RelayLogger = SilentLogger(),
    maxRetries: Int = 3,
    storageDirectory: URL? = nil
  ) {
    self.baseURL = baseURL
    self.appIdentifier = appIdentifier
    self.tokenProvider = tokenProvider
    self.clock = clock
    self.random = random
    self.logger = logger
    self.maxRetries = maxRetries
    self.storageDirectory = storageDirectory
  }
}

/// Caches the current subscriber token and refreshes it shortly before expiry.
actor TokenStore {
  private let provider: any RelayTokenProvider
  private let clock: any RelayClock
  private var current: RelaySubscriberToken?

  init(provider: any RelayTokenProvider, clock: any RelayClock) {
    self.provider = provider
    self.clock = clock
  }

  func token() async throws -> RelaySubscriberToken {
    if let current, current.expiresAt.timeIntervalSince(clock.now()) > 30 {
      return current
    }
    let fresh = try await provider.subscriberToken(forceRefresh: current != nil)
    current = fresh
    return fresh
  }

  func refresh() async throws -> RelaySubscriberToken {
    let fresh = try await provider.subscriberToken(forceRefresh: true)
    current = fresh
    return fresh
  }

  func invalidate() {
    current = nil
  }
}

/// Idempotency keys: random, never derived from content and free of personal data.
enum IdempotencyKey {
  static func make(_ random: any RelayRandom) -> String {
    "rly-" + random.uuid().uuidString.lowercased()
  }
}
