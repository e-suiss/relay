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
    expiresAt: Date? = nil
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
      expiresAt: item.expiresAt
    )
  }
}
