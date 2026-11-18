import Foundation
import UserNotifications

/// The message classes of Relay categories.
public enum RelayMessageClass: String, Sendable, CaseIterable {
  case security
  case actionRequired = "action_required"
  case transactional
  case operational
  case social
  case marketing
  case system
}

/// The operating system notification permission as Relay records it (CH-28).
public enum RelayPermission: String, Sendable, Equatable {
  case granted
  case denied
  case provisional
  case notDetermined = "not_determined"
}

/// The state of a platform notification setting such as Critical Alerts.
public enum RelaySettingState: String, Sendable, Equatable {
  case enabled
  case disabled
  case notSupported = "not_supported"
}

/// What the device allows: the permission and the interruption levels above `active` (CH-65).
public struct RelayNotificationSettings: Sendable, Equatable {
  public var permission: RelayPermission
  public var criticalAlerts: RelaySettingState
  public var timeSensitive: RelaySettingState

  public init(
    permission: RelayPermission,
    criticalAlerts: RelaySettingState = .notSupported,
    timeSensitive: RelaySettingState = .notSupported
  ) {
    self.permission = permission
    self.criticalAlerts = criticalAlerts
    self.timeSensitive = timeSensitive
  }

  // CH-65
  /// The interruption permissions the device reports with its registration. A setting the
  /// platform does not report is left out, so the server keeps the level it has.
  public var interruptionPermissions: RelayInterruptionPermissions {
    RelayInterruptionPermissions(
      criticalAlerts: RelayInterruptionPermission.of(criticalAlerts, permission: permission),
      timeSensitive: RelayInterruptionPermission.of(timeSensitive, permission: permission)
    )
  }
}

// CH-65
/// One interruption permission as Relay records it.
public enum RelayInterruptionPermission: String, Sendable, Equatable {
  case granted
  case denied
  case notDetermined = "not_determined"

  /// Maps a platform setting; `nil` when the platform does not report it.
  public static func of(_ state: RelaySettingState, permission: RelayPermission)
    -> RelayInterruptionPermission?
  {
    switch state {
    case .enabled:
      return .granted
    case .disabled:
      return permission == .notDetermined ? .notDetermined : .denied
    case .notSupported:
      return nil
    }
  }
}

// CH-65
/// The iOS interruption permissions of a device: Critical Alerts and Time Sensitive.
public struct RelayInterruptionPermissions: Sendable, Equatable {
  public var criticalAlerts: RelayInterruptionPermission?
  public var timeSensitive: RelayInterruptionPermission?

  public init(
    criticalAlerts: RelayInterruptionPermission? = nil,
    timeSensitive: RelayInterruptionPermission? = nil
  ) {
    self.criticalAlerts = criticalAlerts
    self.timeSensitive = timeSensitive
  }

  /// Whether nothing is known, so nothing is reported.
  public var isEmpty: Bool { criticalAlerts == nil && timeSensitive == nil }
}

/// Reads the device's notification settings; tests replace it.
public protocol RelayNotificationSettingsReader: Sendable {
  func read() async -> RelayNotificationSettings
}

/// Reads the settings from `UNUserNotificationCenter`.
public struct SystemNotificationSettingsReader: RelayNotificationSettingsReader {
  public init() {}

  public func read() async -> RelayNotificationSettings {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    return RelayNotificationSettings(
      permission: RelayPermissionMapping.permission(settings.authorizationStatus),
      criticalAlerts: RelayPermissionMapping.state(settings.criticalAlertSetting),
      timeSensitive: RelayPermissionMapping.state(settings.timeSensitiveSetting)
    )
  }
}

/// Maps platform values to Relay's permission vocabulary and builds authorization requests.
public enum RelayPermissionMapping {
  public static func permission(_ status: UNAuthorizationStatus) -> RelayPermission {
    switch status {
    case .authorized:
      return .granted
    case .denied:
      return .denied
    case .notDetermined:
      return .notDetermined
    case .provisional:
      return .provisional
    default:
      return .granted
    }
  }

  public static func state(_ setting: UNNotificationSetting) -> RelaySettingState {
    switch setting {
    case .enabled:
      return .enabled
    case .disabled:
      return .disabled
    default:
      return .notSupported
    }
  }

  // CH-29
  /// The options to request for the classes the app will send: provisional authorization only when
  /// every class is `marketing` or `social`; any other class asks for full permission.
  public static func authorizationOptions(
    for classes: Set<RelayMessageClass>,
    criticalAlerts: Bool = false
  ) -> UNAuthorizationOptions {
    var options: UNAuthorizationOptions = [
      .alert, .sound, .badge, .providesAppNotificationSettings,
    ]
    let quiet: Set<RelayMessageClass> = [.marketing, .social]
    if !classes.isEmpty, classes.isSubset(of: quiet) {
      options.insert(.provisional)
    }
    if criticalAlerts, !classes.isSubset(of: quiet) {
      options.insert(.criticalAlert)
    }
    return options
  }
}
