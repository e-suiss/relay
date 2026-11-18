import EsuissRelayAPI
import Foundation

/// The absolute inbox counters; a client keeps only counters newer than its own (IN-18, IN-19).
public struct RelayInboxCounters: Codable, Equatable, Hashable, Sendable {
  public var unseen: Int
  public var unread: Int
  public var total: Int
  public var version: Int

  public init(unseen: Int, unread: Int, total: Int, version: Int) {
    self.unseen = unseen
    self.unread = unread
    self.total = total
    self.version = version
  }

  public static let zero = RelayInboxCounters(unseen: 0, unread: 0, total: 0, version: -1)
}

/// An action button of an inbox item; it is a link, never an approval (IN-6).
public struct RelayInboxAction: Equatable, Hashable, Sendable {
  public let label: String
  public let url: URL?
}

// C-24
// AG-34
/// Who produced a notification; every surface shows it.
public enum RelaySenderType: String, Sendable {
  case human
  case system
  case agent
}

// AG-35
/// The decision request an inbox item is about: a response asked here, or an approval that is
/// decided only on the Access approval surface (IN-6, AG-32).
public struct RelayWaitpoint: Equatable, Hashable, Sendable {
  public enum Kind: String, Sendable {
    case response
    case approval
  }

  public enum Status: String, Sendable {
    case awaiting
    case processing
    case responded
    case notAwaited = "not_awaited"
  }

  /// A structured action a response names by its value.
  public struct Option: Equatable, Hashable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
      self.label = label
      self.value = value
    }
  }

  /// Who resolved the waitpoint.
  public struct Responder: Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable {
      case subscriber
      case agent
    }

    public let kind: Kind
    public let recipientId: String

    public init(kind: Kind, recipientId: String) {
      self.kind = kind
      self.recipientId = recipientId
    }
  }

  public let id: String
  public var kind: Kind
  public var status: Status
  public var subjectDigest: String?
  public var options: [Option]
  public var responder: Responder?
  public var respondedAt: Date?
  public var approvalURL: URL?

  public init(
    id: String,
    kind: Kind = .response,
    status: Status = .awaiting,
    subjectDigest: String? = nil,
    options: [Option] = [],
    responder: Responder? = nil,
    respondedAt: Date? = nil,
    approvalURL: URL? = nil
  ) {
    self.id = id
    self.kind = kind
    self.status = status
    self.subjectDigest = subjectDigest
    self.options = options
    self.responder = responder
    self.respondedAt = respondedAt
    self.approvalURL = approvalURL
  }

  /// Whether a response resolved it or it is not awaited any more.
  public var isClosed: Bool {
    status == .responded || status == .notAwaited
  }

  /// Whether the subscriber can answer it here with one of its options.
  public var isAnswerable: Bool {
    kind == .response && status == .awaiting && subjectDigest != nil && !options.isEmpty
  }
}

// AG-35
/// What became of a response.
public struct RelayWaitpointReceipt: Equatable, Sendable {
  public let waitpointId: String
  public let status: RelayWaitpoint.Status
  public let responder: RelayWaitpoint.Responder?
  public let respondedAt: Date?

  public init(
    waitpointId: String,
    status: RelayWaitpoint.Status,
    responder: RelayWaitpoint.Responder? = nil,
    respondedAt: Date? = nil
  ) {
    self.waitpointId = waitpointId
    self.status = status
    self.responder = responder
    self.respondedAt = respondedAt
  }
}

/// An inbox item as the SDK and its components show it.
public struct RelayInboxItem: Identifiable, Equatable, Hashable, Sendable {
  public enum Kind: String, Sendable {
    case personal
    case announcement
  }

  public let id: String
  public var kind: Kind
  public var stateVersion: Int
  public var seen: Bool
  public var read: Bool
  public var archived: Bool
  public var hidden: Bool
  public var expired: Bool
  public var snoozedUntil: Date?
  public var createdAt: Date
  public var lastActivityAt: Date
  public var category: String?
  public var tags: [String]
  public var groupKey: String?
  public var title: String?
  public var body: String?
  public var avatarURL: URL?
  public var url: URL?
  public var actions: [RelayInboxAction]
  public var data: [String: String]
  public var locale: String?
  public var isRightToLeft: Bool
  public var activityCount: Int
  public var actorCount: Int
  public var expiresAt: Date?
  public var senderType: RelaySenderType?
  public var isApproval: Bool
  public var waitpoint: RelayWaitpoint?

  public init(
    id: String,
    kind: Kind = .personal,
    stateVersion: Int,
    seen: Bool = false,
    read: Bool = false,
    archived: Bool = false,
    hidden: Bool = false,
    expired: Bool = false,
    snoozedUntil: Date? = nil,
    createdAt: Date,
    lastActivityAt: Date? = nil,
    category: String? = nil,
    tags: [String] = [],
    groupKey: String? = nil,
    title: String? = nil,
    body: String? = nil,
    avatarURL: URL? = nil,
    url: URL? = nil,
    actions: [RelayInboxAction] = [],
    data: [String: String] = [:],
    locale: String? = nil,
    isRightToLeft: Bool = false,
    activityCount: Int = 1,
    actorCount: Int = 0,
    expiresAt: Date? = nil,
    senderType: RelaySenderType? = nil,
    isApproval: Bool = false,
    waitpoint: RelayWaitpoint? = nil
  ) {
    self.id = id
    self.kind = kind
    self.stateVersion = stateVersion
    self.seen = seen
    self.read = read
    self.archived = archived
    self.hidden = hidden
    self.expired = expired
    self.snoozedUntil = snoozedUntil
    self.createdAt = createdAt
    self.lastActivityAt = lastActivityAt ?? createdAt
    self.category = category
    self.tags = tags
    self.groupKey = groupKey
    self.title = title
    self.body = body
    self.avatarURL = avatarURL
    self.url = url
    self.actions = actions
    self.data = data
    self.locale = locale
    self.isRightToLeft = isRightToLeft
    self.activityCount = activityCount
    self.actorCount = actorCount
    self.expiresAt = expiresAt
    self.senderType = senderType
    self.isApproval = isApproval
    self.waitpoint = waitpoint
  }

  /// Applies a server state; an older or equal `state_version` is ignored (IN-5).
  public mutating func apply(_ state: RelayItemState) {
    guard state.stateVersion > stateVersion else { return }
    stateVersion = state.stateVersion
    seen = state.seen
    read = state.read
    archived = state.archived
    hidden = state.hidden
    expired = state.expired
  }

  /// Whether the item belongs in the inbox tab.
  public var isVisibleInInbox: Bool {
    !hidden && !expired && !archived && snoozedUntil == nil
  }

  /// Whether the item is an approval request: its only action is the link to the Access approval
  /// surface and it is never answered here (IN-6, AG-32).
  public var isApprovalRequest: Bool {
    isApproval || waitpoint?.kind == .approval
  }

  /// The deep link to the Access approval surface of an approval item.
  public var approvalURL: URL? {
    guard isApprovalRequest else { return nil }
    return waitpoint?.approvalURL ?? actions.first?.url
  }

  /// Whether the subscriber can answer the item's waitpoint here.
  public var isAnswerable: Bool {
    !isApprovalRequest && (waitpoint?.isAnswerable ?? false)
  }
}

/// A page of inbox items with the counters and stream cursor of its first page.
public struct RelayInboxPage: Equatable, Sendable {
  public let items: [RelayInboxItem]
  public let hasMore: Bool
  public let nextCursor: String?
  public let counters: RelayInboxCounters?
  public let streamCursor: String?
}

/// One change of a delta sync (IN-29).
public enum RelayInboxChange: Equatable, Sendable {
  case upsert(RelayInboxItem)
  case removed(RelayItemState)
}

/// The answer of a delta sync.
public struct RelayInboxDelta: Equatable, Sendable {
  public let changes: [RelayInboxChange]
  public let cursor: String
  public let hasMore: Bool
  public let needsColdSync: Bool
  public let counters: RelayInboxCounters
}

/// The inbox list filter.
public enum RelayInboxFilter: String, Sendable, CaseIterable {
  case inbox
  case unread
  case archived
  case snoozed
  case all
}

extension RelayInboxCounters {
  init(_ counters: Components.Schemas.InboxCounters) {
    self.init(
      unseen: counters.unseen,
      unread: counters.unread,
      total: counters.total,
      version: counters.version
    )
  }

  init(_ counters: Components.Schemas.RealtimeEnvelope.CountersPayload) {
    self.init(
      unseen: counters.unseen,
      unread: counters.unread,
      total: counters.total,
      version: counters.version
    )
  }
}

extension RelayItemState {
  init(_ state: Components.Schemas.InboxItemState) {
    self.init(
      id: state.id,
      stateVersion: state.stateVersion,
      seen: state.seen,
      read: state.read,
      archived: state.archived,
      hidden: state.hidden,
      expired: state.expired
    )
  }
}

extension RelayInboxItem {
  init(_ item: Components.Schemas.InboxItem) {
    var data: [String: String] = [:]
    for pair in item.data { data[pair.key] = pair.value }
    self.init(
      id: item.id,
      kind: item.kind == .announcement ? .announcement : .personal,
      stateVersion: item.stateVersion,
      seen: item.seen,
      read: item.read,
      archived: item.archived,
      hidden: item.hidden,
      expired: item.expired,
      snoozedUntil: item.snoozedUntil,
      createdAt: item.createdAt,
      lastActivityAt: item.lastActivityAt,
      category: item.category,
      tags: item.tags,
      groupKey: item.groupKey,
      title: item.title,
      body: item.body,
      avatarURL: item.avatarUrl.flatMap(URL.init(string:)),
      url: item.url.flatMap(URL.init(string:)),
      actions: item.actions.map { RelayInboxAction(label: $0.label, url: URL(string: $0.url)) },
      data: data,
      locale: item.locale,
      isRightToLeft: item.dir == .rtl,
      activityCount: item.activityCount,
      actorCount: item.actorCount,
      expiresAt: item.expiresAt,
      senderType: item.senderType.flatMap { RelaySenderType(rawValue: $0.rawValue) },
      isApproval: item.approval ?? false,
      waitpoint: item.waitpoint.map(RelayWaitpoint.init)
    )
  }
}

extension RelayWaitpoint {
  init(_ waitpoint: Components.Schemas.InboxWaitpoint) {
    self.init(
      id: waitpoint.id,
      kind: waitpoint.kind == .approval ? .approval : .response,
      status: Status(rawValue: waitpoint.status.rawValue) ?? .awaiting,
      subjectDigest: waitpoint.subjectDigest,
      options: waitpoint.options.map { Option(label: $0.label, value: $0.value) },
      responder: waitpoint.responder.map {
        Responder(kind: $0.kind == .agent ? .agent : .subscriber, recipientId: $0.recipientId)
      },
      respondedAt: waitpoint.respondedAt,
      approvalURL: waitpoint.approvalUrl.flatMap(URL.init(string:))
    )
  }
}
