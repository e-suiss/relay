import Foundation

/// Time source of the SDK; tests replace it to control backoff and expiry without waiting.
public protocol RelayClock: Sendable {
  func now() -> Date
  func sleep(seconds: TimeInterval) async throws
}

/// Randomness of the SDK (jitter and idempotency keys); tests replace it with a fixed sequence.
public protocol RelayRandom: Sendable {
  func unit() -> Double
  func uuid() -> UUID
}

/// Receives the SDK's diagnostic messages. Messages never carry tokens, push tokens or device status values.
public protocol RelayLogger: Sendable {
  func log(_ level: RelayLogLevel, _ message: String)
}

/// Severity of a diagnostic message.
public enum RelayLogLevel: String, Sendable {
  case debug
  case info
  case warning
  case error
}

/// The wall clock and `Task.sleep`.
public struct SystemClock: RelayClock {
  public init() {}

  public func now() -> Date { Date() }

  public func sleep(seconds: TimeInterval) async throws {
    guard seconds > 0 else { return }
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
  }
}

/// The system random number generator.
public struct SystemRandom: RelayRandom {
  public init() {}

  public func unit() -> Double { Double.random(in: 0..<1) }

  public func uuid() -> UUID { UUID() }
}

/// A logger that drops every message.
public struct SilentLogger: RelayLogger {
  public init() {}

  public func log(_ level: RelayLogLevel, _ message: String) {}
}
