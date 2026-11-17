import Foundation
import OpenAPIRuntime

// X-31
/// The Relay subscriber client of an iOS app: inbox, preferences, push devices and realtime with the
/// mobile lifecycle. It only acts for the subscriber of its token and never triggers events.
@MainActor
public final class RelayClient: RelayLifecycleSteps {
  public let configuration: RelayConfiguration
  public let inbox: RelayInboxAPI
  public let push: RelayPushAPI
  public let preferences: RelayPreferencesAPI
  public let store: RelayInboxStore
  public let realtime: RelayRealtimeConnection
  public let remover: RelayNotificationRemover
  public private(set) var lifecycle: RelayLifecycle!

  let http: RelayHTTP

  public convenience init(configuration: RelayConfiguration) {
    let queueURL = (configuration.storageDirectory
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
      .appendingPathComponent("EsuissRelay/intents.json")
    self.init(
      configuration: configuration,
      transport: nil,
      realtimeTransports: nil,
      deviceStorage: UserDefaultsDeviceStorage(),
      queueStorage: FileIntentQueueStorage(url: queueURL),
      settings: SystemNotificationSettingsReader(),
      delivered: SystemDeliveredNotificationCenter()
    )
  }

  init(
    configuration: RelayConfiguration,
    transport: (any ClientTransport)?,
    realtimeTransports: [any RelayRealtimeTransport]?,
    deviceStorage: any RelayDeviceStorage,
    queueStorage: any IntentQueueStorage,
    settings: any RelayNotificationSettingsReader,
    delivered: any RelayDeliveredNotificationCenter
  ) {
    self.configuration = configuration
    let http = RelayHTTP(configuration: configuration, transport: transport)
    self.http = http
    let inbox = RelayInboxAPI(http: http)
    self.inbox = inbox
    self.push = RelayPushAPI(http: http, storage: deviceStorage, settings: settings)
    self.preferences = RelayPreferencesAPI(http: http)
    self.store = RelayInboxStore(
      api: inbox,
      queue: IntentQueue(storage: queueStorage, random: configuration.random),
      clock: configuration.clock
    )
    let deviceId: @Sendable () -> String? = { deviceStorage.load()?.deviceId }
    let transports =
      realtimeTransports ?? [
        WebSocketRealtimeTransport(baseURL: configuration.baseURL, deviceId: deviceId),
        ServerSentEventsRealtimeTransport(baseURL: configuration.baseURL, deviceId: deviceId),
        LongPollRealtimeTransport(http: http),
      ]
    self.realtime = RelayRealtimeConnection(
      transports: transports,
      tokens: http.tokens,
      clock: configuration.clock,
      random: configuration.random
    )
    self.remover = RelayNotificationRemover(center: delivered)
    self.lifecycle = RelayLifecycle(steps: self)
    let store = self.store
    let remover = self.remover
    store.onItemsRemoved = { items in
      Task { await remover.remove(items: items) }
    }
    let realtime = self.realtime
    Task {
      await realtime.onEnvelope { [weak store] envelope in
        await store?.handle(envelope)
      }
    }
  }

  // IN-35
  /// Handles a background push. A sync signal refreshes the counters and runs a delta sync; it
  /// carries no inbox content. Returns whether the push was a Relay sync signal.
  @discardableResult
  public func handleBackgroundPush(userInfo: [AnyHashable: Any]) async -> Bool {
    guard let payload = RelayPushPayload(userInfo: userInfo), payload.isSyncSignal else {
      return false
    }
    await store.refreshCounters()
    await store.synchronize()
    if store.counters.unread == 0 { await remover.removeAll() }
    return true
  }

  // CH-32
  /// Records the click of a Relay notification and marks its item read.
  public func handleNotificationOpened(userInfo: [AnyHashable: Any]) async {
    guard let payload = RelayPushPayload(userInfo: userInfo) else { return }
    if let deliveryId = payload.deliveryId {
      try? await push.record(.clicked, deliveryId: deliveryId)
    }
    if let itemId = payload.itemId, let item = store.items.first(where: { $0.id == itemId }) {
      await store.perform(.click, on: item)
    }
  }

  /// Records that a Relay notification was displayed while the app was in the foreground.
  public func handleNotificationDisplayed(userInfo: [AnyHashable: Any]) async {
    guard let deliveryId = RelayPushPayload(userInfo: userInfo)?.deliveryId else { return }
    try? await push.record(.displayed, deliveryId: deliveryId)
  }

  public func refreshCounters() async { await store.refreshCounters() }

  public func connectRealtime() async { await realtime.connect(cursor: store.streamCursor) }

  public func synchronize() async { await store.synchronize() }

  public func drainQueue() async { await store.drainQueue() }

  public func disconnectRealtime() async { await realtime.disconnect() }
}
