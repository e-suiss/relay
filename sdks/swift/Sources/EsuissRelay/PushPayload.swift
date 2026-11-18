import Foundation

// CH-33
// IN-35
/// The Relay part of a push: the opaque identifier, the subject topic and link, or a sync signal.
public struct RelayPushPayload: Equatable, Sendable {
  public let id: String?
  public let topic: String?
  public let url: URL?
  public let isSyncSignal: Bool
  public let counterVersion: Int?
  public let neutralTitle: String?
  public let neutralBody: String?

  public init(
    id: String? = nil,
    topic: String? = nil,
    url: URL? = nil,
    isSyncSignal: Bool = false,
    counterVersion: Int? = nil,
    neutralTitle: String? = nil,
    neutralBody: String? = nil
  ) {
    self.id = id
    self.topic = topic
    self.url = url
    self.isSyncSignal = isSyncSignal
    self.counterVersion = counterVersion
    self.neutralTitle = neutralTitle
    self.neutralBody = neutralBody
  }

  /// Reads an APNs payload (`userInfo`), whose Relay members are under `relay`.
  public init?(userInfo: [AnyHashable: Any]) {
    guard let relay = userInfo["relay"] as? [String: Any] else { return nil }
    self.init(
      id: relay["id"] as? String,
      topic: relay["topic"] as? String,
      url: (relay["url"] as? String).flatMap(URL.init(string:)),
      isSyncSignal: (relay["sync"] as? Bool) ?? false,
      counterVersion: (relay["counter_version"] as? NSNumber)?.intValue,
      neutralTitle: nil,
      neutralBody: nil
    )
  }

  /// Reads FCM or HMS data members (`relay_id`, `relay_topic`, `relay_url`, neutral texts).
  public init?(data: [String: String]) {
    let id = data["relay_id"] ?? data["id"]
    let sync = data["sync"] == "true" || data["relay_sync"] == "true"
    guard id != nil || sync else { return nil }
    self.init(
      id: id,
      topic: data["relay_topic"],
      url: data["relay_url"].flatMap(URL.init(string:)),
      isSyncSignal: sync,
      counterVersion: (data["counter_version"] ?? data["relay_counter_version"]).flatMap {
        Int($0)
      },
      neutralTitle: data["relay_neutral_title"],
      neutralBody: data["relay_neutral_body"]
    )
  }

  /// The delivery the push belongs to, when the identifier is a delivery id.
  public var deliveryId: String? {
    guard let id, id.hasPrefix("dlv_") else { return nil }
    return id
  }

  /// The inbox item the push shows, when the identifier is an inbox item id.
  public var itemId: String? {
    guard let id, id.hasPrefix("inb_") || id.hasPrefix("ann_") else { return nil }
    return id
  }
}

// CH-33
/// The generic text shown when the content of a content-free push cannot be fetched.
public enum RelayNeutralText {
  public static func title(locale: Locale = .current) -> String {
    isTurkish(locale) ? "Yeni bildirim" : "New notification"
  }

  public static func body(locale: Locale = .current) -> String {
    isTurkish(locale) ? "Yeni bir bildiriminiz var." : "You have a new notification."
  }

  static func isTurkish(_ locale: Locale) -> Bool {
    locale.identifier.lowercased().hasPrefix("tr")
  }
}
