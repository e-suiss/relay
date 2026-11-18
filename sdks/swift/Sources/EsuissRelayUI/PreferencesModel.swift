import EsuissRelay
import Foundation

/// What the host app knows about a category: its name, class and whether a digest is allowed.
public struct RelayCategoryInfo: Sendable, Equatable {
  public let key: String
  public let name: String
  public let messageClass: RelayMessageClass
  public let digestAllowed: Bool

  public init(
    key: String, name: String, messageClass: RelayMessageClass, digestAllowed: Bool = false
  ) {
    self.key = key
    self.name = name
    self.messageClass = messageClass
    self.digestAllowed = digestAllowed || messageClass == .social
  }
}

// PC-15
// PC-16
// X-51
/// How one cell is shown.
public enum RelayPreferenceRowState: Equatable, Sendable {
  case on
  case off
  case lockedOn
  case adminDisabled
  case deviceDisabled
  case permissionPending

  /// Whether the user can change the cell from the component.
  public var isEditable: Bool {
    self == .on || self == .off
  }

  public static func of(_ cell: RelayPreferenceCell, permission: RelayPermission)
    -> RelayPreferenceRowState
  {
    if cell.locked { return .lockedOn }
    if cell.disabledByAdmin { return .adminDisabled }
    if cell.disabledInDeviceSettings { return .deviceDisabled }
    if cell.channel == "push" {
      switch permission {
      case .denied:
        return .deviceDisabled
      case .notDetermined:
        return .permissionPending
      case .granted, .provisional:
        break
      }
    }
    return cell.effective ? .on : .off
  }
}

// PC-17
/// The three choices shown when the user turns a digest category off; none is preselected.
public enum RelayTurnOffChoice: String, Sendable, CaseIterable {
  case instant
  case digest
  case never
}

/// The preference centre state behind `RelayPreferencesView`.
@MainActor
public final class RelayPreferencesModel: ObservableObject {
  @Published public private(set) var preferences: RelayPreferences?
  @Published public private(set) var permission: RelayPermission = .notDetermined
  @Published public private(set) var lastError: RelayError?
  @Published public var pendingTurnOff: RelayPreferenceCell?

  public let categories: [String: RelayCategoryInfo]
  let api: RelayPreferencesAPI
  let settings: any RelayNotificationSettingsReader

  public init(
    api: RelayPreferencesAPI,
    categories: [RelayCategoryInfo] = [],
    settings: any RelayNotificationSettingsReader = SystemNotificationSettingsReader()
  ) {
    self.api = api
    self.settings = settings
    var map: [String: RelayCategoryInfo] = [:]
    for category in categories { map[category.key] = category }
    self.categories = map
  }

  public func load() async {
    permission = await settings.read().permission
    do {
      preferences = try await api.load()
    } catch {
      lastError = error as? RelayError ?? .invalidResponse("preferences")
    }
  }

  public func state(of cell: RelayPreferenceCell) -> RelayPreferenceRowState {
    RelayPreferenceRowState.of(cell, permission: permission)
  }

  public func name(of category: String) -> String {
    if let name = categories[category]?.name { return name }
    if let cell = preferences?.cells(for: category).first { return cell.categoryName }
    return category
  }

  /// Turns a cell on, or off; turning a digest category off first asks the three-choice question.
  public func set(_ cell: RelayPreferenceCell, on: Bool) async {
    if on {
      await write {
        try await $0.set(category: cell.category, channel: cell.channel, value: .optIn)
      }
      return
    }
    if cell.digestAllowed {
      pendingTurnOff = cell
      return
    }
    await write { try await $0.set(category: cell.category, channel: cell.channel, value: .optOut) }
  }

  // PC-17
  public func choose(_ choice: RelayTurnOffChoice) async {
    guard let cell = pendingTurnOff else { return }
    pendingTurnOff = nil
    switch choice {
    case .instant:
      guard let current = preferences else { return }
      await write {
        try await $0.setDigest(category: cell.category, choice: .instant, current: current)
      }
    case .digest:
      guard let current = preferences else { return }
      await write {
        try await $0.setDigest(category: cell.category, choice: .digest, current: current)
      }
    case .never:
      await write {
        try await $0.set(category: cell.category, channel: cell.channel, value: .optOut)
      }
    }
  }

  private func write(_ change: (RelayPreferencesAPI) async throws -> RelayPreferences) async {
    do {
      preferences = try await change(api)
    } catch {
      lastError = error as? RelayError ?? .invalidResponse("preferences")
    }
  }
}
