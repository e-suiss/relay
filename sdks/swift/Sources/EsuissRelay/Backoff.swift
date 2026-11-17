import Foundation

// IN-34
// IN-52
/// Exponential backoff with full jitter: attempt n waits a uniform time in [0, min(cap, base * 2^n)].
public struct FullJitterBackoff: Sendable {
  public let base: TimeInterval
  public let cap: TimeInterval

  public init(base: TimeInterval = 1, cap: TimeInterval = 60) {
    self.base = base
    self.cap = cap
  }

  /// The upper bound of the wait before attempt `attempt` (0 based).
  public func ceiling(attempt: Int) -> TimeInterval {
    let exponent = min(max(attempt, 0), 30)
    return min(cap, base * pow(2, Double(exponent)))
  }

  /// The wait before attempt `attempt`; a server `Retry-After` is a floor the wait never goes below.
  public func delay(attempt: Int, random: RelayRandom, retryAfter: TimeInterval? = nil)
    -> TimeInterval
  {
    let jittered = random.unit() * ceiling(attempt: attempt)
    guard let retryAfter, retryAfter > 0 else { return jittered }
    return max(retryAfter, jittered)
  }
}
