import EsuissRelayAPI
import Foundation

/// The realtime transports, in the order the SDK tries them (IN-23).
public enum RelayRealtimeTransportKind: String, Sendable, CaseIterable {
  case webSocket = "websocket"
  case serverSentEvents = "sse"
  case longPoll = "poll"
}

/// Why a transport stopped.
public enum RelayRealtimeStop: Error, Equatable, Sendable {
  case unavailable
  case retryAfter(TimeInterval)
  case authExpired
  case refused(String)
  case closed
}

/// The state of the realtime connection.
public enum RelayRealtimeState: Equatable, Sendable {
  case disconnected
  case connecting(RelayRealtimeTransportKind)
  case connected(RelayRealtimeTransportKind)
  case waiting(TimeInterval)
  case stopped(String)
}

/// One realtime transport; `run` returns or throws when the connection ends.
public protocol RelayRealtimeTransport: Sendable {
  var kind: RelayRealtimeTransportKind { get }
  func run(
    cursor: String?,
    token: String,
    onOpen: @escaping @Sendable () async -> Void,
    onEnvelope: @escaping @Sendable (RelayRealtimeEnvelope) async -> Void
  ) async throws
}

// IN-34
// IN-35
/// Keeps one realtime connection while the app is in the foreground: WebSocket first, then SSE, then
/// long-poll; every reconnect waits with full jitter (1 to 60 seconds) and honours `Retry-After`.
public actor RelayRealtimeConnection {
  private let transports: [any RelayRealtimeTransport]
  private let tokens: TokenStore
  private let clock: any RelayClock
  private let random: any RelayRandom
  private let backoff = FullJitterBackoff(base: 1, cap: 60)
  private var task: Task<Void, Never>?
  private var handler: (@Sendable (RelayRealtimeEnvelope) async -> Void)?
  private var stateHandler: (@Sendable (RelayRealtimeState) async -> Void)?
  private(set) var cursor: String?
  public private(set) var state: RelayRealtimeState = .disconnected

  init(
    transports: [any RelayRealtimeTransport],
    tokens: TokenStore,
    clock: any RelayClock,
    random: any RelayRandom
  ) {
    self.transports = transports
    self.tokens = tokens
    self.clock = clock
    self.random = random
  }

  public func onEnvelope(_ handler: @escaping @Sendable (RelayRealtimeEnvelope) async -> Void) {
    self.handler = handler
  }

  public func onState(_ handler: @escaping @Sendable (RelayRealtimeState) async -> Void) {
    self.stateHandler = handler
  }

  /// Opens the stream after `cursor`, or at the head with the current counters when it is `nil`.
  public func connect(cursor: String?) {
    if let cursor { self.cursor = cursor }
    guard task == nil else { return }
    task = Task { [weak self] in
      await self?.loop()
    }
  }

  /// Closes the connection (the app went to the background, IN-35).
  public func disconnect() async {
    task?.cancel()
    task = nil
    await set(.disconnected)
  }

  private func loop() async {
    var index = 0
    var attempt = 0
    while !Task.isCancelled, !transports.isEmpty {
      let transport = transports[index]
      await set(.connecting(transport.kind))
      var wait: TimeInterval?
      do {
        let token = try await tokens.token()
        try await transport.run(
          cursor: cursor,
          token: token.value,
          onOpen: { [weak self] in
            await self?.opened(transport.kind)
          },
          onEnvelope: { [weak self] envelope in
            await self?.deliver(envelope)
          }
        )
        attempt = 0
      } catch let stop as RelayRealtimeStop {
        switch stop {
        case .unavailable:
          if index + 1 < transports.count {
            index += 1
            continue
          }
        case let .retryAfter(seconds):
          wait = seconds
        case .authExpired:
          _ = try? await tokens.refresh()
          continue
        case let .refused(reason):
          await set(.stopped(reason))
          task = nil
          return
        case .closed:
          break
        }
      } catch {
        if Task.isCancelled { return }
      }
      if Task.isCancelled { return }
      let delay = backoff.delay(attempt: attempt, random: random, retryAfter: wait)
      attempt += 1
      await set(.waiting(delay))
      do {
        try await clock.sleep(seconds: delay)
      } catch {
        return
      }
    }
  }

  private func opened(_ kind: RelayRealtimeTransportKind) async {
    await set(.connected(kind))
  }

  private func deliver(_ envelope: RelayRealtimeEnvelope) async {
    if let id = envelope.id { cursor = id }
    await handler?(envelope)
  }

  private func set(_ newState: RelayRealtimeState) async {
    state = newState
    await stateHandler?(newState)
  }
}

/// The Phoenix Channels WebSocket at `/v1/realtime/websocket`.
public struct WebSocketRealtimeTransport: RelayRealtimeTransport {
  public let kind = RelayRealtimeTransportKind.webSocket
  let baseURL: URL
  let deviceId: @Sendable () -> String?
  let session: URLSession

  public init(baseURL: URL, session: URLSession = .shared, deviceId: @escaping @Sendable () -> String?) {
    self.baseURL = baseURL
    self.session = session
    self.deviceId = deviceId
  }

  public func run(
    cursor: String?,
    token: String,
    onOpen: @escaping @Sendable () async -> Void,
    onEnvelope: @escaping @Sendable (RelayRealtimeEnvelope) async -> Void
  ) async throws {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw RelayRealtimeStop.unavailable
    }
    components.scheme = components.scheme == "http" ? "ws" : "wss"
    components.path = "/v1/realtime/websocket"
    var query = [URLQueryItem(name: "vsn", value: "2.0.0")]
    if let device = deviceId() { query.append(URLQueryItem(name: "device_id", value: device)) }
    components.queryItems = query
    guard let url = components.url else { throw RelayRealtimeStop.unavailable }
    let socket = session.webSocketTask(with: url, protocols: PhoenixFrame.subprotocols(token: token))
    socket.resume()
    defer { socket.cancel(with: .goingAway, reason: nil) }
    var payload: [String: Any] = [:]
    if let cursor { payload["cursor"] = cursor }
    let join = PhoenixFrame(
      joinRef: "1",
      ref: "1",
      topic: "inbox",
      event: "phx_join",
      payload: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    )
    do {
      try await socket.send(.string(join.encoded()))
    } catch {
      throw RelayRealtimeStop.unavailable
    }
    let heartbeat = Task {
      var ref = 1
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        ref += 1
        let frame = PhoenixFrame(
          joinRef: nil,
          ref: "h\(ref)",
          topic: "phoenix",
          event: "heartbeat",
          payload: Data("{}".utf8)
        )
        try? await socket.send(.string(frame.encoded()))
      }
    }
    defer { heartbeat.cancel() }
    var joined = false
    while !Task.isCancelled {
      let message: URLSessionWebSocketTask.Message
      do {
        message = try await socket.receive()
      } catch {
        throw WebSocketRealtimeTransport.stop(
          reason: socket.closeReason.map { String(decoding: $0, as: UTF8.self) },
          joined: joined
        )
      }
      guard case let .string(text) = message, let frame = PhoenixFrame.decode(text) else { continue }
      if frame.event == "phx_reply", frame.ref == "1" {
        let reply = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any]
        guard reply?["status"] as? String == "ok" else {
          let response = reply?["response"] as? [String: Any]
          throw RelayRealtimeStop.refused(response?["reason"] as? String ?? "join_refused")
        }
        joined = true
        await onOpen()
        continue
      }
      if frame.event == "phx_error" || frame.event == "phx_close" { throw RelayRealtimeStop.closed }
      guard frame.topic == "inbox", let envelope = RelayRealtimeEnvelope(json: frame.payload) else {
        continue
      }
      await onEnvelope(envelope)
    }
  }

  // IN-33
  // IN-52
  /// Maps a close reason of the server to how the SDK continues.
  public static func stop(reason: String?, joined: Bool) -> RelayRealtimeStop {
    guard let reason, !reason.isEmpty else { return joined ? .closed : .unavailable }
    if reason.hasPrefix("retry-after=") {
      return .retryAfter(TimeInterval(reason.dropFirst("retry-after=".count)) ?? 1)
    }
    switch reason {
    case "auth_expired_token", "auth_invalid_token":
      return .authExpired
    case "connection_limit":
      return .closed
    default:
      return .refused(reason)
    }
  }
}

/// The SSE stream at `/v1/realtime/events`.
public struct ServerSentEventsRealtimeTransport: RelayRealtimeTransport {
  public let kind = RelayRealtimeTransportKind.serverSentEvents
  let baseURL: URL
  let deviceId: @Sendable () -> String?
  let session: URLSession

  public init(baseURL: URL, session: URLSession = .shared, deviceId: @escaping @Sendable () -> String?) {
    self.baseURL = baseURL
    self.session = session
    self.deviceId = deviceId
  }

  public func run(
    cursor: String?,
    token: String,
    onOpen: @escaping @Sendable () async -> Void,
    onEnvelope: @escaping @Sendable (RelayRealtimeEnvelope) async -> Void
  ) async throws {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("v1/realtime/events"),
      resolvingAgainstBaseURL: false
    )
    if let device = deviceId() { components?.queryItems = [URLQueryItem(name: "device_id", value: device)] }
    guard let url = components?.url else { throw RelayRealtimeStop.unavailable }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue(RelayConfiguration.apiVersion, forHTTPHeaderField: "Relay-Version")
    if let cursor { request.setValue(cursor, forHTTPHeaderField: "Last-Event-ID") }
    request.timeoutInterval = 90
    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
    do {
      (bytes, response) = try await session.bytes(for: request)
    } catch {
      throw RelayRealtimeStop.unavailable
    }
    guard let http = response as? HTTPURLResponse else { throw RelayRealtimeStop.unavailable }
    if http.statusCode != 200 {
      throw ServerSentEventsRealtimeTransport.stop(
        status: http.statusCode,
        retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
      )
    }
    await onOpen()
    var splitter = LineSplitter()
    var parser = ServerSentEventParser()
    for try await byte in bytes {
      guard let line = splitter.feed(byte), let event = parser.feed(line: line) else { continue }
      if let envelope = RelayRealtimeEnvelope(json: Data(event.data.utf8)) {
        await onEnvelope(envelope)
      }
    }
    throw RelayRealtimeStop.closed
  }

  /// Maps an HTTP answer of the stream to how the SDK continues.
  public static func stop(status: Int, retryAfter: TimeInterval?) -> RelayRealtimeStop {
    switch status {
    case 401:
      return .authExpired
    case 429, 503:
      return .retryAfter(retryAfter ?? 1)
    case 403:
      return .refused("forbidden")
    case 404:
      return .unavailable
    default:
      return status >= 500 ? .closed : .refused("status_\(status)")
    }
  }
}

/// The long-poll at `/v1/realtime/poll`, the last-resort transport.
struct LongPollRealtimeTransport: RelayRealtimeTransport {
  let kind = RelayRealtimeTransportKind.longPoll
  let http: RelayHTTP

  func run(
    cursor: String?,
    token: String,
    onOpen: @escaping @Sendable () async -> Void,
    onEnvelope: @escaping @Sendable (RelayRealtimeEnvelope) async -> Void
  ) async throws {
    var next = cursor
    var opened = false
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    while !Task.isCancelled {
      let poll: Components.Schemas.RealtimePoll
      do {
        let current = next
        poll = try await http.perform(scope: .inboxRead) { client in
          let output = try await client.pollRealtimeEvents(.init(query: .init(cursor: current)))
          guard case let .ok(ok) = output else {
            throw RelayError.invalidResponse("pollRealtimeEvents")
          }
          return try ok.body.json
        }
      } catch let error as RelayError {
        if case let .problem(problem, retryAfter) = error {
          throw ServerSentEventsRealtimeTransport.stop(status: problem.status, retryAfter: retryAfter)
        }
        throw RelayRealtimeStop.closed
      }
      if !opened {
        opened = true
        await onOpen()
      }
      for event in poll.events {
        guard let data = try? encoder.encode(event), let envelope = RelayRealtimeEnvelope(json: data)
        else { continue }
        await onEnvelope(envelope)
      }
      next = poll.cursor
    }
  }
}
