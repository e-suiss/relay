import Foundation

// IN-12
/// A state intent on an inbox item.
public enum RelayInboxOperation: String, Codable, Sendable, CaseIterable {
  case seen
  case read
  case unread
  case archive
  case unarchive
  case hide
  case snooze
  case unsnooze
  case click

  /// Reverse intents apply only on the current `state_version`; monotone ones apply unconditionally.
  public var isReverse: Bool {
    switch self {
    case .unread, .unarchive, .unsnooze:
      return true
    default:
      return false
    }
  }
}

// IN-13
/// One intent waiting in the offline queue.
public struct QueuedIntent: Codable, Equatable, Sendable {
  public let itemId: String
  public let operation: RelayInboxOperation
  public let clientSeq: Int
  public let baseStateVersion: Int?
  public let snoozeUntil: Date?
  /// Kept with the intent so every send of it, across retries and restarts, uses the same key.
  public let idempotencyKey: String
}

/// The persisted queue: the next `client_seq` and the waiting intents.
public struct IntentQueueSnapshot: Codable, Equatable, Sendable {
  public var nextSeq: Int
  public var entries: [QueuedIntent]

  public init(nextSeq: Int = 0, entries: [QueuedIntent] = []) {
    self.nextSeq = nextSeq
    self.entries = entries
  }
}

/// Where the offline queue survives app restarts.
public protocol IntentQueueStorage: Sendable {
  func load() -> IntentQueueSnapshot?
  func save(_ snapshot: IntentQueueSnapshot)
}

/// Keeps the queue in memory only.
public final class MemoryIntentQueueStorage: IntentQueueStorage, @unchecked Sendable {
  private let lock = NSLock()
  private var snapshot: IntentQueueSnapshot?

  public init(_ snapshot: IntentQueueSnapshot? = nil) {
    self.snapshot = snapshot
  }

  public func load() -> IntentQueueSnapshot? {
    lock.lock()
    defer { lock.unlock() }
    return snapshot
  }

  public func save(_ snapshot: IntentQueueSnapshot) {
    lock.lock()
    defer { lock.unlock() }
    self.snapshot = snapshot
  }
}

/// Keeps the queue in a JSON file protected until first unlock.
public struct FileIntentQueueStorage: IntentQueueStorage {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public func load() -> IntentQueueSnapshot? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(IntentQueueSnapshot.self, from: data)
  }

  public func save(_ snapshot: IntentQueueSnapshot) {
    guard let data = try? JSONEncoder().encode(snapshot) else { return }
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    #if os(iOS)
      try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
      try? data.write(to: url, options: [.atomic])
    #endif
  }
}

// IN-13
/// The offline intent queue: ordered by `client_seq` and compacted per item, so only the last
/// intent of an item waits; a reverse intent older than the server state is dropped.
public actor IntentQueue {
  private let storage: any IntentQueueStorage
  private let random: any RelayRandom
  private var snapshot: IntentQueueSnapshot

  public init(storage: any IntentQueueStorage, random: any RelayRandom = SystemRandom()) {
    self.storage = storage
    self.random = random
    self.snapshot = storage.load() ?? IntentQueueSnapshot()
  }

  @discardableResult
  public func enqueue(
    itemId: String,
    operation: RelayInboxOperation,
    baseStateVersion: Int?,
    snoozeUntil: Date? = nil
  ) -> QueuedIntent {
    let intent = QueuedIntent(
      itemId: itemId,
      operation: operation,
      clientSeq: snapshot.nextSeq,
      baseStateVersion: baseStateVersion,
      snoozeUntil: snoozeUntil,
      idempotencyKey: IdempotencyKey.make(random)
    )
    snapshot.nextSeq += 1
    snapshot.entries.removeAll { $0.itemId == itemId }
    snapshot.entries.append(intent)
    storage.save(snapshot)
    return intent
  }

  public func pending() -> [QueuedIntent] {
    snapshot.entries.sorted { $0.clientSeq < $1.clientSeq }
  }

  public func remove(clientSeq: Int) {
    snapshot.entries.removeAll { $0.clientSeq == clientSeq }
    storage.save(snapshot)
  }

  /// Applies a server state seen through sync or realtime: a waiting reverse intent based on an
  /// older `state_version` can no longer win and leaves the queue; monotone intents stay.
  public func observe(itemId: String, stateVersion: Int) {
    let before = snapshot.entries.count
    snapshot.entries.removeAll { intent in
      intent.itemId == itemId && intent.operation.isReverse
        && (intent.baseStateVersion ?? 0) < stateVersion
    }
    if snapshot.entries.count != before { storage.save(snapshot) }
  }

  public var isEmpty: Bool { snapshot.entries.isEmpty }
}
