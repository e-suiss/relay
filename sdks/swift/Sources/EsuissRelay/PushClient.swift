import Foundation

extension RelayPushAPI {
  /// A push API without the inbox and realtime parts, for a Notification Service Extension. Give it
  /// the device storage the app uses (an App Group suite) so receipts name the same device.
  public static func make(
    configuration: RelayConfiguration,
    deviceStorage: any RelayDeviceStorage
  ) -> RelayPushAPI {
    RelayPushAPI(
      http: RelayHTTP(configuration: configuration),
      storage: deviceStorage,
      settings: SystemNotificationSettingsReader()
    )
  }
}
