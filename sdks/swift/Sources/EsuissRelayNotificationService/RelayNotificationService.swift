import EsuissRelay
import Foundation
import UserNotifications

// CH-33
/// Fills a content-free Relay push in a Notification Service Extension. It fetches the content by
/// the delivery id the push carries over TLS with the subscriber token and records the displayed
/// receipt; when the content cannot be read in time the generic text stays, and the content never
/// falls back into the push payload.
public struct RelayNotificationContentFiller: Sendable {
  let resolve: @Sendable (RelayPushPayload) async -> RelayPushContent?
  let receipt: @Sendable (String) async -> Void

  public init(
    resolve: @escaping @Sendable (RelayPushPayload) async -> RelayPushContent?,
    receipt: @escaping @Sendable (String) async -> Void
  ) {
    self.resolve = resolve
    self.receipt = receipt
  }

  public init(push: RelayPushAPI) {
    self.init(
      resolve: { payload in await push.content(for: payload) },
      receipt: { deliveryId in try? await push.record(.displayed, deliveryId: deliveryId) }
    )
  }

  /// The content to show for a request: the fetched title and body, or the generic text.
  public func fill(_ content: UNMutableNotificationContent, locale: Locale = .current) async
    -> UNMutableNotificationContent
  {
    guard let payload = RelayPushPayload(userInfo: content.userInfo) else { return content }
    if let deliveryId = payload.deliveryId { await receipt(deliveryId) }
    if let fetched = await resolve(payload), fetched.hasText {
      content.title = fetched.title ?? ""
      content.subtitle = fetched.subtitle ?? ""
      content.body = fetched.body ?? ""
      if let url = fetched.url {
        var userInfo = content.userInfo
        var relay = userInfo["relay"] as? [String: Any] ?? [:]
        relay["url"] = url.absoluteString
        userInfo["relay"] = relay
        content.userInfo = userInfo
      }
      return content
    }
    if content.title.isEmpty && content.body.isEmpty {
      content.title = payload.neutralTitle ?? RelayNeutralText.title(locale: locale)
      content.body = payload.neutralBody ?? RelayNeutralText.body(locale: locale)
    }
    return content
  }
}

/// A Notification Service Extension principal class for Relay pushes. Subclass it and return a
/// configured `RelayPushAPI` from `makePushAPI()`; the extension reads its subscriber token through
/// the host app's token provider (for example from a shared keychain group).
open class RelayNotificationService: UNNotificationServiceExtension {
  private var handler: ((UNNotificationContent) -> Void)?
  private var best: UNMutableNotificationContent?
  private var work: Task<Void, Never>?

  open func makePushAPI() -> RelayPushAPI? { nil }

  open override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    handler = contentHandler
    guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
      contentHandler(request.content)
      return
    }
    best = content
    guard let push = makePushAPI() else {
      contentHandler(content)
      return
    }
    let filler = RelayNotificationContentFiller(push: push)
    work = Task { [weak self] in
      let filled = await filler.fill(content)
      await MainActor.run { self?.finish(filled) }
    }
  }

  open override func serviceExtensionTimeWillExpire() {
    work?.cancel()
    if let best { finish(best) }
  }

  private func finish(_ content: UNNotificationContent) {
    guard let handler else { return }
    self.handler = nil
    handler(content)
  }
}
