import Foundation

/// One realtime envelope `{t, v, ts, id, d, counters}` (IN-26).
public struct RelayRealtimeEnvelope: Equatable, Sendable {
  public let type: String
  public let version: Int
  public let id: String?
  public let payload: Data
  public let counters: RelayInboxCounters

  public init(type: String, version: Int, id: String?, payload: Data, counters: RelayInboxCounters)
  {
    self.type = type
    self.version = version
    self.id = id
    self.payload = payload
    self.counters = counters
  }

  /// Decodes an envelope from its JSON object.
  public init?(object: Any) {
    guard let map = object as? [String: Any],
      let type = map["t"] as? String,
      let counters = map["counters"] as? [String: Any],
      let unseen = (counters["unseen"] as? NSNumber)?.intValue,
      let unread = (counters["unread"] as? NSNumber)?.intValue,
      let total = (counters["total"] as? NSNumber)?.intValue,
      let version = (counters["version"] as? NSNumber)?.intValue
    else { return nil }
    let data =
      map["d"].flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data("{}".utf8)
    self.init(
      type: type,
      version: (map["v"] as? NSNumber)?.intValue ?? 1,
      id: map["id"] as? String,
      payload: data,
      counters: RelayInboxCounters(unseen: unseen, unread: unread, total: total, version: version)
    )
  }

  public init?(json: Data) {
    guard let object = try? JSONSerialization.jsonObject(with: json) else { return nil }
    self.init(object: object)
  }

  /// The state change of `inbox.item_updated`: only the fields the server sent.
  public var itemPatch: RelayItemPatch? {
    guard type == "inbox.item_updated",
      let map = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
      let id = map["item_id"] as? String,
      let stateVersion = (map["state_version"] as? NSNumber)?.intValue
    else { return nil }
    let changes = map["changes"] as? [String: Any] ?? [:]
    return RelayItemPatch(
      id: id,
      stateVersion: stateVersion,
      seen: changes["seen"] as? Bool,
      read: changes["read"] as? Bool,
      archived: changes["archived"] as? Bool,
      hidden: changes["hidden"] as? Bool,
      expired: changes["expired"] as? Bool
    )
  }

  /// The item of `inbox.item_created`: its JSON, and whether it is thin (IN-27, IN-49).
  public var createdItem: (id: String, json: Data, thin: Bool)? {
    guard type == "inbox.item_created",
      let map = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
      let item = map["item"] as? [String: Any],
      let id = item["id"] as? String,
      let json = try? JSONSerialization.data(withJSONObject: item)
    else { return nil }
    return (id, json, map["thin"] as? Bool ?? false)
  }
}

/// A partial state change of an inbox item.
public struct RelayItemPatch: Equatable, Sendable {
  public let id: String
  public let stateVersion: Int
  public let seen: Bool?
  public let read: Bool?
  public let archived: Bool?
  public let hidden: Bool?
  public let expired: Bool?

  public init(
    id: String,
    stateVersion: Int,
    seen: Bool? = nil,
    read: Bool? = nil,
    archived: Bool? = nil,
    hidden: Bool? = nil,
    expired: Bool? = nil
  ) {
    self.id = id
    self.stateVersion = stateVersion
    self.seen = seen
    self.read = read
    self.archived = archived
    self.hidden = hidden
    self.expired = expired
  }
}

/// One Server-Sent Event.
public struct ServerSentEvent: Equatable, Sendable {
  public var event: String?
  public var data: String
  public var id: String?
}

// IN-23
/// Incremental `text/event-stream` parser: feed it lines without their terminators.
public struct ServerSentEventParser: Sendable {
  private var event: String?
  private var data: [String] = []
  private var id: String?

  public init() {}

  public mutating func feed(line: String) -> ServerSentEvent? {
    if line.isEmpty {
      defer {
        event = nil
        data = []
      }
      guard !data.isEmpty else { return nil }
      return ServerSentEvent(event: event, data: data.joined(separator: "\n"), id: id)
    }
    if line.hasPrefix(":") { return nil }
    let field: Substring
    var value: Substring
    if let colon = line.firstIndex(of: ":") {
      field = line[line.startIndex..<colon]
      value = line[line.index(after: colon)...]
      if value.hasPrefix(" ") { value = value.dropFirst() }
    } else {
      field = Substring(line)
      value = ""
    }
    switch field {
    case "event": event = String(value)
    case "data": data.append(String(value))
    case "id": id = String(value)
    default: break
    }
    return nil
  }
}

/// Splits a byte stream into lines, keeping empty lines (SSE dispatches on them).
public struct LineSplitter: Sendable {
  private var buffer: [UInt8] = []
  private var lastWasCarriageReturn = false

  public init() {}

  public mutating func feed(_ byte: UInt8) -> String? {
    if byte == UInt8(ascii: "\n") {
      if lastWasCarriageReturn {
        lastWasCarriageReturn = false
        return nil
      }
      return flush()
    }
    if byte == UInt8(ascii: "\r") {
      lastWasCarriageReturn = true
      return flush()
    }
    lastWasCarriageReturn = false
    buffer.append(byte)
    return nil
  }

  private mutating func flush() -> String {
    defer { buffer.removeAll(keepingCapacity: true) }
    return String(decoding: buffer, as: UTF8.self)
  }
}

// IN-23
/// The Phoenix Channels v2 JSON frame `[join_ref, ref, topic, event, payload]`.
public struct PhoenixFrame: Sendable, Equatable {
  public let joinRef: String?
  public let ref: String?
  public let topic: String
  public let event: String
  public let payload: Data

  public init(joinRef: String?, ref: String?, topic: String, event: String, payload: Data) {
    self.joinRef = joinRef
    self.ref = ref
    self.topic = topic
    self.event = event
    self.payload = payload
  }

  public func encoded() -> String {
    let payloadObject = (try? JSONSerialization.jsonObject(with: payload)) ?? [String: Any]()
    let array: [Any] = [
      joinRef.map { $0 as Any } ?? NSNull(),
      ref.map { $0 as Any } ?? NSNull(),
      topic,
      event,
      payloadObject,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: array) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
  }

  public static func decode(_ text: String) -> PhoenixFrame? {
    guard let array = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any],
      array.count == 5,
      let topic = array[2] as? String,
      let event = array[3] as? String,
      let payload = try? JSONSerialization.data(withJSONObject: array[4])
    else { return nil }
    return PhoenixFrame(
      joinRef: array[0] as? String,
      ref: array[1] as? String,
      topic: topic,
      event: event,
      payload: payload
    )
  }

  /// The WebSocket subprotocols that carry the subscriber token as the channels `authToken`.
  public static func subprotocols(token: String) -> [String] {
    let encoded = Data(token.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return ["phoenix", "base64url.bearer.phx.\(encoded)"]
  }
}
