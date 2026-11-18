import EsuissRelayAPI
import Foundation
import OpenAPIRuntime

/// The subscriber's own inbox over REST (scopes `inbox:read` and `inbox:write`). Writes are intents,
/// never states (IN-12, IN-31).
public final class RelayInboxAPI: Sendable {
  let http: RelayHTTP

  init(http: RelayHTTP) {
    self.http = http
  }

  /// A keyset page of items; the first page also carries the counters and the stream cursor.
  public func list(
    filter: RelayInboxFilter = .inbox,
    category: String? = nil,
    limit: Int? = nil,
    startingAfter: String? = nil
  ) async throws -> RelayInboxPage {
    try await http.perform(scope: .inboxRead) { client in
      let output = try await client.listMyInboxItems(
        .init(
          query: .init(
            limit: limit,
            startingAfter: startingAfter,
            status: .init(rawValue: filter.rawValue),
            category: category
          )
        )
      )
      guard case .ok(let ok) = output else { throw RelayError.invalidResponse("listMyInboxItems") }
      let list = try ok.body.json
      return RelayInboxPage(
        items: list.data.map(RelayInboxItem.init),
        hasMore: list.hasMore,
        nextCursor: list.nextCursor,
        counters: list.counters.map(RelayInboxCounters.init),
        streamCursor: list.cursor
      )
    }
  }

  public func item(id: String) async throws -> RelayInboxItem {
    try await http.perform(scope: .inboxRead) { client in
      let output = try await client.getMyInboxItem(.init(path: .init(itemId: id)))
      guard case .ok(let ok) = output else { throw RelayError.invalidResponse("getMyInboxItem") }
      return RelayInboxItem(try ok.body.json)
    }
  }

  public func counters() async throws -> RelayInboxCounters {
    try await http.perform(scope: .inboxRead) { client in
      let output = try await client.getMyInboxCounters(.init())
      guard case .ok(let ok) = output else {
        throw RelayError.invalidResponse("getMyInboxCounters")
      }
      return RelayInboxCounters(try ok.body.json)
    }
  }

  // IN-29
  public func changes(since cursor: String, limit: Int? = nil) async throws -> RelayInboxDelta {
    try await http.perform(scope: .inboxRead) { client in
      let output = try await client.listMyInboxChanges(
        .init(query: .init(since: cursor, limit: limit))
      )
      guard case .ok(let ok) = output else {
        throw RelayError.invalidResponse("listMyInboxChanges")
      }
      let delta = try ok.body.json
      let changes: [RelayInboxChange] = delta.changes.compactMap { change in
        if change._type != .removed, let item = change.item.value1 {
          return .upsert(RelayInboxItem(item))
        }
        if let state = change.item.value2 { return .removed(RelayItemState(state)) }
        if let item = change.item.value1 {
          return .removed(
            RelayItemState(
              id: item.id,
              stateVersion: item.stateVersion,
              seen: item.seen,
              read: item.read,
              archived: item.archived,
              hidden: true,
              expired: item.expired
            )
          )
        }
        return nil
      }
      return RelayInboxDelta(
        changes: changes,
        cursor: delta.cursor,
        hasMore: delta.hasMore,
        needsColdSync: delta.truncated || delta.resyncRequired,
        counters: RelayInboxCounters(delta.counters)
      )
    }
  }

  // IN-14
  public func markAllRead(category: String? = nil) async throws -> RelayInboxCounters {
    let key = IdempotencyKey.make(http.configuration.random)
    return try await http.perform(scope: .inboxWrite) { client in
      let output = try await client.markAllMyInboxRead(
        .init(headers: .init(idempotencyKey: key), body: .json(.init(category: category)))
      )
      guard case .ok(let ok) = output else {
        throw RelayError.invalidResponse("markAllMyInboxRead")
      }
      return RelayInboxCounters(try ok.body.json.counters)
    }
  }

  // AG-26
  // AG-35
  /// Responds to a waitpoint that asks the subscriber with one of its option values, carrying the
  /// subject digest the item showed. A response is never an approval: an approval waitpoint is
  /// decided only on the Access approval surface (AG-32).
  public func respond(to waitpoint: RelayWaitpoint, value: String) async throws
    -> RelayWaitpointReceipt
  {
    guard waitpoint.kind == .response, let digest = waitpoint.subjectDigest else {
      throw RelayError.invalidResponse("waitpoint is not answerable")
    }
    let response = try OpenAPIValueContainer(unvalidatedValue: value)
    return try await http.perform(scope: .inboxWrite) { client in
      let output = try await client.respondToMyWaitpoint(
        .init(
          path: .init(waitpointId: waitpoint.id),
          body: .json(.init(response: response, subjectDigest: digest))
        )
      )
      guard case .ok(let ok) = output else {
        throw RelayError.invalidResponse("respondToMyWaitpoint")
      }
      let receipt = try ok.body.json
      return RelayWaitpointReceipt(
        waitpointId: receipt.waitpointId,
        status: RelayWaitpoint.Status(rawValue: receipt.status.rawValue) ?? .processing,
        responder: receipt.responder.map {
          RelayWaitpoint.Responder(
            kind: $0.kind == .agent ? .agent : .subscriber,
            recipientId: $0.recipientId
          )
        },
        respondedAt: receipt.respondedAt
      )
    }
  }

  // IN-12
  /// Sends one queued intent with the idempotency key it was queued with.
  public func send(_ intent: QueuedIntent) async throws -> (RelayItemState, RelayInboxCounters) {
    let key = intent.idempotencyKey
    return try await http.perform(scope: .inboxWrite) { client in
      let body = Components.Schemas.InboxIntent(
        baseStateVersion: intent.baseStateVersion,
        clientSeq: intent.clientSeq,
        op: Components.Schemas.InboxIntent.OpPayload(rawValue: intent.operation.rawValue) ?? .seen,
        snoozeUntil: intent.snoozeUntil
      )
      let output = try await client.applyMyInboxIntent(
        .init(
          path: .init(itemId: intent.itemId),
          headers: .init(idempotencyKey: key),
          body: .json(body)
        )
      )
      guard case .ok(let ok) = output else {
        throw RelayError.invalidResponse("applyMyInboxIntent")
      }
      let result = try ok.body.json
      return (RelayItemState(result.state), RelayInboxCounters(result.counters))
    }
  }
}
