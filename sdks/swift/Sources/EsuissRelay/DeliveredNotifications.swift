import Foundation
import UserNotifications

/// A notification shown on the device, with its Relay identifier and topic.
public struct RelayDeliveredNotification: Equatable, Sendable {
  public let identifier: String
  public let relayId: String?
  public let topic: String?

  public init(identifier: String, relayId: String?, topic: String?) {
    self.identifier = identifier
    self.relayId = relayId
    self.topic = topic
  }
}

/// The notifications shown on the device; tests replace it.
public protocol RelayDeliveredNotificationCenter: Sendable {
  func delivered() async -> [RelayDeliveredNotification]
  func remove(identifiers: [String]) async
}

/// The shown notifications of `UNUserNotificationCenter`.
public struct SystemDeliveredNotificationCenter: RelayDeliveredNotificationCenter {
  public init() {}

  public func delivered() async -> [RelayDeliveredNotification] {
    let notifications = await UNUserNotificationCenter.current().deliveredNotifications()
    return notifications.map { notification in
      let payload = RelayPushPayload(userInfo: notification.request.content.userInfo)
      return RelayDeliveredNotification(
        identifier: notification.request.identifier,
        relayId: payload?.id,
        topic: payload?.topic ?? notification.request.content.threadIdentifier
      )
    }
  }

  public func remove(identifiers: [String]) async {
    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
  }
}

// IN-38
/// Removes the shown notifications of items read or removed on any device. iOS removal goes through
/// the SDK and may lag.
public struct RelayNotificationRemover: Sendable {
  let center: any RelayDeliveredNotificationCenter

  public init(center: any RelayDeliveredNotificationCenter) {
    self.center = center
  }

  public func remove(items: [RelayInboxItem]) async {
    guard !items.isEmpty else { return }
    let ids = Set(items.map(\.id))
    let topics = Set(items.compactMap(\.groupKey))
    let matching = await center.delivered().filter { notification in
      if let relayId = notification.relayId, ids.contains(relayId) { return true }
      if let topic = notification.topic, !topic.isEmpty, topics.contains(topic) { return true }
      return false
    }
    guard !matching.isEmpty else { return }
    await center.remove(identifiers: matching.map(\.identifier))
  }

  /// Removes every shown Relay notification once nothing is unread.
  public func removeAll() async {
    let relay = await center.delivered().filter { $0.relayId != nil }
    guard !relay.isEmpty else { return }
    await center.remove(identifiers: relay.map(\.identifier))
  }
}
