import EsuissRelay
import Foundation
import UserNotifications

// PC-18
// CH-32
/// A `UNUserNotificationCenterDelegate` for Relay pushes: records displayed and clicked receipts,
/// and opens the preference centre from the system notification settings.
@MainActor
public final class RelayNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
  let client: RelayClient
  let router: RelayPreferencesRouter
  let onOpenURL: (URL) -> Void

  public init(
    client: RelayClient, router: RelayPreferencesRouter, onOpenURL: @escaping (URL) -> Void
  ) {
    self.client = client
    self.router = router
    self.onOpenURL = onOpenURL
  }

  public nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let userInfo = notification.request.content.userInfo
    let box = UserInfoBox(userInfo)
    Task { @MainActor in
      await self.client.handleNotificationDisplayed(userInfo: box.userInfo)
    }
    completionHandler([.banner, .list, .sound])
  }

  public nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let box = UserInfoBox(response.notification.request.content.userInfo)
    Task { @MainActor in
      await self.client.handleNotificationOpened(userInfo: box.userInfo)
      if let url = RelayPushPayload(userInfo: box.userInfo)?.url { self.onOpenURL(url) }
      completionHandler()
    }
  }

  public nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    openSettingsFor notification: UNNotification?
  ) {
    Task { @MainActor in self.router.open() }
  }
}

private struct UserInfoBox: @unchecked Sendable {
  let userInfo: [AnyHashable: Any]

  init(_ userInfo: [AnyHashable: Any]) {
    self.userInfo = userInfo
  }
}
