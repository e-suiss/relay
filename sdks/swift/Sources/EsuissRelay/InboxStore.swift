import Combine
import EsuissRelayAPI
import Foundation

/// A message the inbox shows once.
public enum RelayInboxNotice: Equatable, Sendable {
  /// A reverse change the user just made lost to a newer change on another device (IN-12).
  case updatedOnAnotherDevice(itemId: String)
}

/// The inbox state the components observe: items, counters, sync and the offline intent queue.
@MainActor
public final class RelayInboxStore: ObservableObject {
  @Published public private(set) var items: [RelayInboxItem] = []
  @Published public private(set) var counters: RelayInboxCounters = .zero
  @Published public private(set) var hasMore = false
  @Published public private(set) var isLoading = false
  @Published public var notice: RelayInboxNotice?
  @Published public private(set) var lastError: RelayError?

  public private(set) var streamCursor: String?
  public var undoWindow: TimeInterval = 4
  /// Called with the items that became read or left the inbox, to remove their notifications (IN-38).
  public var onItemsRemoved: (@MainActor ([RelayInboxItem]) -> Void)?

  let api: RelayInboxAPI
  let queue: IntentQueue
  let clock: any RelayClock
  private var nextCursor: String?
  private var reversalsThisSession: Set<String> = []
  private var pendingUndo: (item: RelayInboxItem, task: Task<Void, Never>)?
  private var draining = false

  init(api: RelayInboxAPI, queue: IntentQueue, clock: any RelayClock) {
    self.api = api
    self.queue = queue
    self.clock = clock
  }

  // IN-18
  /// Keeps counters only when they are newer than the ones shown.
  public func apply(counters newCounters: RelayInboxCounters) {
    guard newCounters.version > counters.version else { return }
    counters = newCounters
  }

  public func refreshCounters() async {
    do {
      apply(counters: try await api.counters())
    } catch {
      record(error)
    }
  }

  // IN-29
  /// A delta sync from the stream cursor, or a cold sync when there is none or it no longer holds.
  public func synchronize() async {
    guard let cursor = streamCursor else {
      await coldSync()
      return
    }
    do {
      var since = cursor
      while true {
        let delta = try await api.changes(since: since)
        if delta.needsColdSync {
          await coldSync()
          return
        }
        for change in delta.changes { await apply(change) }
        apply(counters: delta.counters)
        since = delta.cursor
        streamCursor = delta.cursor
        if !delta.hasMore { break }
      }
    } catch {
      record(error)
    }
  }

  /// Reads the first page again and replaces the list.
  public func coldSync() async {
    isLoading = true
    defer { isLoading = false }
    do {
      let page = try await api.list(filter: .inbox)
      items = page.items.filter(\.isVisibleInInbox)
      hasMore = page.hasMore
      nextCursor = page.nextCursor
      if let pageCounters = page.counters { apply(counters: pageCounters) }
      if let cursor = page.streamCursor { streamCursor = cursor }
      for item in page.items { await queue.observe(itemId: item.id, stateVersion: item.stateVersion) }
    } catch {
      record(error)
    }
  }

  public func loadMore() async {
    guard hasMore, let cursor = nextCursor, !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let page = try await api.list(filter: .inbox, startingAfter: cursor)
      let known = Set(items.map(\.id))
      items.append(contentsOf: page.items.filter { $0.isVisibleInInbox && !known.contains($0.id) })
      hasMore = page.hasMore
      nextCursor = page.nextCursor
    } catch {
      record(error)
    }
  }

  // IN-26
  // IN-28
  /// Applies one realtime envelope; an item is only replaced by a newer `state_version`.
  public func handle(_ envelope: RelayRealtimeEnvelope) async {
    apply(counters: envelope.counters)
    if let id = envelope.id { streamCursor = id }
    switch envelope.type {
    case "inbox.item_updated":
      guard let patch = envelope.itemPatch else { return }
      apply(patch)
      await queue.observe(itemId: patch.id, stateVersion: patch.stateVersion)
    case "inbox.item_created":
      guard let created = envelope.createdItem else { return }
      if !created.thin, let item = RelayInboxStore.decodeItem(created.json) {
        insert(item)
      } else if let item = try? await api.item(id: created.id) {
        insert(item)
      }
    case "inbox.items_bulk_updated", "stream.resync_required":
      await coldSync()
    default:
      break
    }
  }

  // IN-12
  // IN-15
  /// Applies an intent on screen at once, queues it and sends it; hide and archive wait for the undo
  /// window first.
  public func perform(_ operation: RelayInboxOperation, on item: RelayInboxItem, snoozeUntil: Date? = nil)
    async
  {
    let undoable = operation == .archive || operation == .hide
    if operation.isReverse { reversalsThisSession.insert(item.id) }
    applyOptimistic(operation, to: item.id)
    if undoable {
      pendingUndo?.task.cancel()
      let window = undoWindow
      let task = Task { [weak self, clock] in
        try? await clock.sleep(seconds: window)
        guard !Task.isCancelled else { return }
        await self?.commit(operation, item: item, snoozeUntil: snoozeUntil)
      }
      pendingUndo = (item, task)
      return
    }
    await commit(operation, item: item, snoozeUntil: snoozeUntil)
  }

  /// Takes back the last hide or archive before it reached the server.
  public func undo() {
    guard let pending = pendingUndo else { return }
    pending.task.cancel()
    pendingUndo = nil
    insert(pending.item, force: true)
  }

  public func markAllRead() async {
    let unread = items.filter { !$0.read }
    for index in items.indices {
      items[index].read = true
      items[index].seen = true
    }
    do {
      apply(counters: try await api.markAllRead())
      onItemsRemoved?(unread)
    } catch {
      record(error)
    }
  }

  /// Marks the items the user saw (IN-9).
  public func markSeen(_ visible: [RelayInboxItem]) async {
    let unseen = visible.filter { !$0.seen }
    guard !unseen.isEmpty else { return }
    for item in unseen {
      applyOptimistic(.seen, to: item.id)
      await queue.enqueue(itemId: item.id, operation: .seen, baseStateVersion: item.stateVersion)
    }
    await drainQueue()
  }

  // IN-13
  /// Sends the waiting intents in `client_seq` order. A conflict is accepted silently; the notice
  /// appears only when the user made that reverse change in this session.
  public func drainQueue() async {
    guard !draining else { return }
    draining = true
    defer { draining = false }
    for intent in await queue.pending() {
      do {
        let (state, newCounters) = try await api.send(intent)
        await queue.remove(clientSeq: intent.clientSeq)
        apply(state: state)
        apply(counters: newCounters)
      } catch let error as RelayError {
        if case let .problem(problem, _) = error, problem.code == "inbox_item_conflict" {
          await queue.remove(clientSeq: intent.clientSeq)
          if let current = problem.current { apply(state: current) }
          if intent.operation.isReverse, reversalsThisSession.contains(intent.itemId) {
            notice = .updatedOnAnotherDevice(itemId: intent.itemId)
          }
          continue
        }
        if error.isRetryable {
          record(error)
          return
        }
        await queue.remove(clientSeq: intent.clientSeq)
        record(error)
      } catch {
        return
      }
    }
    reversalsThisSession.removeAll()
  }

  private func commit(_ operation: RelayInboxOperation, item: RelayInboxItem, snoozeUntil: Date?) async {
    if pendingUndo?.item.id == item.id { pendingUndo = nil }
    await queue.enqueue(
      itemId: item.id,
      operation: operation,
      baseStateVersion: item.stateVersion,
      snoozeUntil: snoozeUntil
    )
    await drainQueue()
  }

  private func applyOptimistic(_ operation: RelayInboxOperation, to id: String) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    var item = items[index]
    switch operation {
    case .seen:
      if !item.seen { counters.unseen = max(0, counters.unseen - 1) }
      item.seen = true
    case .read, .click:
      if !item.seen { counters.unseen = max(0, counters.unseen - 1) }
      if !item.read { counters.unread = max(0, counters.unread - 1) }
      item.seen = true
      item.read = true
    case .unread:
      if item.read { counters.unread += 1 }
      item.read = false
    case .archive:
      item.archived = true
    case .unarchive:
      item.archived = false
    case .hide:
      item.hidden = true
    case .snooze:
      item.snoozedUntil = clock.now().addingTimeInterval(3600)
    case .unsnooze:
      item.snoozedUntil = nil
    }
    if item.isVisibleInInbox {
      items[index] = item
    } else {
      items.remove(at: index)
      onItemsRemoved?([item])
    }
    if operation == .read || operation == .click { onItemsRemoved?([item]) }
  }

  private func apply(_ change: RelayInboxChange) async {
    switch change {
    case let .upsert(item):
      await queue.observe(itemId: item.id, stateVersion: item.stateVersion)
      insert(item)
    case let .removed(state):
      await queue.observe(itemId: state.id, stateVersion: state.stateVersion)
      if let index = items.firstIndex(where: { $0.id == state.id }) {
        let removed = items.remove(at: index)
        onItemsRemoved?([removed])
      }
    }
  }

  private func apply(state: RelayItemState) {
    guard let index = items.firstIndex(where: { $0.id == state.id }) else { return }
    var item = items[index]
    let wasRead = item.read
    item.apply(state)
    if item.isVisibleInInbox {
      items[index] = item
      if item.read, !wasRead { onItemsRemoved?([item]) }
    } else {
      items.remove(at: index)
      onItemsRemoved?([item])
    }
  }

  private func apply(_ patch: RelayItemPatch) {
    guard let index = items.firstIndex(where: { $0.id == patch.id }) else { return }
    var item = items[index]
    guard patch.stateVersion > item.stateVersion else { return }
    let wasRead = item.read
    item.stateVersion = patch.stateVersion
    if let seen = patch.seen { item.seen = seen }
    if let read = patch.read { item.read = read }
    if let archived = patch.archived { item.archived = archived }
    if let hidden = patch.hidden { item.hidden = hidden }
    if let expired = patch.expired { item.expired = expired }
    if item.isVisibleInInbox {
      items[index] = item
      if item.read, !wasRead { onItemsRemoved?([item]) }
    } else {
      items.remove(at: index)
      onItemsRemoved?([item])
    }
  }

  private func insert(_ item: RelayInboxItem, force: Bool = false) {
    if let index = items.firstIndex(where: { $0.id == item.id }) {
      guard force || item.stateVersion > items[index].stateVersion else { return }
      if item.isVisibleInInbox || force {
        items[index] = item
      } else {
        items.remove(at: index)
      }
      return
    }
    guard item.isVisibleInInbox || force else { return }
    items.append(item)
    items.sort { $0.lastActivityAt > $1.lastActivityAt }
  }

  private func record(_ error: any Error) {
    lastError = RelayHTTP.unwrap(error)
  }

  static func decodeItem(_ json: Data) -> RelayInboxItem? {
    let decoder = JSONDecoder()
    let transcoder = RelayDateTranscoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      return try transcoder.decode(try container.decode(String.self))
    }
    guard let item = try? decoder.decode(Components.Schemas.InboxItem.self, from: json) else {
      return nil
    }
    return RelayInboxItem(item)
  }
}
