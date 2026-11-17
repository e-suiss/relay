import Foundation

/// RFC 9457 problem details returned by Relay.
public struct RelayProblem: Decodable, Equatable, Sendable {
  public let type: String
  public let title: String
  public let status: Int
  public let code: String
  public let detail: String?
  public let retryable: Bool?
  public let requestId: String?
  public let retryAfter: Int?
  /// The item state a conflicting inbox intent lost to (`inbox_item_conflict`, IN-12).
  public let current: RelayItemState?

  public init(
    type: String,
    title: String,
    status: Int,
    code: String,
    detail: String? = nil,
    retryable: Bool? = nil,
    requestId: String? = nil,
    retryAfter: Int? = nil,
    current: RelayItemState? = nil
  ) {
    self.type = type
    self.title = title
    self.status = status
    self.code = code
    self.detail = detail
    self.retryable = retryable
    self.requestId = requestId
    self.retryAfter = retryAfter
    self.current = current
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decode(String.self, forKey: .type)
    title = try container.decode(String.self, forKey: .title)
    status = try container.decode(Int.self, forKey: .status)
    code = try container.decode(String.self, forKey: .code)
    detail = try container.decodeIfPresent(String.self, forKey: .detail)
    retryable = try container.decodeIfPresent(Bool.self, forKey: .retryable)
    requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
    retryAfter = try container.decodeIfPresent(Int.self, forKey: .retryAfter)
    current = try? container.decodeIfPresent(RelayItemState.self, forKey: .current)
  }

  enum CodingKeys: String, CodingKey {
    case type
    case title
    case status
    case code
    case detail
    case retryable
    case requestId = "request_id"
    case retryAfter = "retry_after"
    case current
  }
}

/// The state of an inbox item without its content.
public struct RelayItemState: Codable, Equatable, Hashable, Sendable {
  public var id: String
  public var stateVersion: Int
  public var seen: Bool
  public var read: Bool
  public var archived: Bool
  public var hidden: Bool
  public var expired: Bool

  public init(
    id: String,
    stateVersion: Int,
    seen: Bool,
    read: Bool,
    archived: Bool,
    hidden: Bool,
    expired: Bool
  ) {
    self.id = id
    self.stateVersion = stateVersion
    self.seen = seen
    self.read = read
    self.archived = archived
    self.hidden = hidden
    self.expired = expired
  }

  enum CodingKeys: String, CodingKey {
    case id
    case stateVersion = "state_version"
    case seen
    case read
    case archived
    case hidden
    case expired
  }
}

/// Errors thrown by the SDK.
public enum RelayError: Error, Equatable, Sendable {
  case problem(RelayProblem, retryAfter: TimeInterval?)
  case transport(String)
  case missingScope(RelayScope)
  case unexpectedStatus(Int)
  case invalidResponse(String)
  case notRegistered

  /// Whether repeating the same request, with the same idempotency key, can succeed.
  public var isRetryable: Bool {
    switch self {
    case let .problem(problem, _):
      return RetryClassifier.isRetryable(
        status: problem.status,
        code: problem.code,
        declared: problem.retryable
      )
    case .transport:
      return true
    case let .unexpectedStatus(status):
      return RetryClassifier.isRetryable(status: status, code: nil, declared: nil)
    case .missingScope, .invalidResponse, .notRegistered:
      return false
    }
  }

  /// The server's `Retry-After`, in seconds, when it sent one.
  public var retryAfter: TimeInterval? {
    if case let .problem(problem, header) = self {
      return header ?? problem.retryAfter.map(TimeInterval.init)
    }
    return nil
  }

  /// The problem code, when the error is a problem response.
  public var code: String? {
    if case let .problem(problem, _) = self { return problem.code }
    return nil
  }
}

// X-29
/// The retryable mapping of the error catalog: the problem's own `retryable` member wins, and the
/// status defaults of the catalog apply when the body carries none.
public enum RetryClassifier {
  public static func isRetryable(status: Int, code: String?, declared: Bool?) -> Bool {
    if let declared { return declared }
    return defaultRetryable(status: status, code: code)
  }

  /// The catalog's `retryable_defaults` for a status and, where the catalog splits a status, a code.
  public static func defaultRetryable(status: Int, code: String?) -> Bool {
    switch status {
    case 409:
      return code == "idempotency_key_in_progress"
    case 429:
      return code != "quota_exhausted"
    case 500, 503, 504:
      return true
    default:
      return false
    }
  }
}
