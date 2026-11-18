import EsuissRelay
import Foundation
import SwiftUI

// X-32
/// Colours and shapes of the Relay components; a brand (or a subtenant brand) sets its own values.
public struct RelayTheme: Sendable {
  public var accent: Color
  public var background: Color
  public var primaryText: Color
  public var secondaryText: Color
  public var unreadIndicator: Color
  public var destructive: Color
  public var cornerRadius: CGFloat

  public init(
    accent: Color = .accentColor,
    background: Color = .clear,
    primaryText: Color = .primary,
    secondaryText: Color = .secondary,
    unreadIndicator: Color = .accentColor,
    destructive: Color = .red,
    cornerRadius: CGFloat = 12
  ) {
    self.accent = accent
    self.background = background
    self.primaryText = primaryText
    self.secondaryText = secondaryText
    self.unreadIndicator = unreadIndicator
    self.destructive = destructive
    self.cornerRadius = cornerRadius
  }

  public static let standard = RelayTheme()
}

private struct RelayThemeKey: EnvironmentKey {
  static let defaultValue = RelayTheme.standard
}

extension EnvironmentValues {
  /// The theme the Relay components read.
  public var relayTheme: RelayTheme {
    get { self[RelayThemeKey.self] }
    set { self[RelayThemeKey.self] = newValue }
  }
}

extension View {
  /// Sets the theme of the Relay components below this view.
  public func relayTheme(_ theme: RelayTheme) -> some View {
    environment(\.relayTheme, theme)
  }
}

// X-32
/// The component texts in Turkish and English; other languages fall back to English.
public struct RelayStrings: Sendable {
  public let locale: Locale

  public init(locale: Locale = .current) {
    self.locale = locale
  }

  public func text(_ key: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: bundle, value: key, comment: "")
  }

  public func bellLabel(unseen: Int) -> String {
    unseen > 0 ? String(format: text("bell.label"), unseen) : text("bell.labelNone")
  }

  public func channelName(_ channel: String) -> String {
    text("channel.\(channel)")
  }

  var bundle: Bundle {
    let language = locale.identifier.lowercased().hasPrefix("tr") ? "tr" : "en"
    guard let path = Bundle.module.path(forResource: language, ofType: "lproj"),
      let bundle = Bundle(path: path)
    else { return Bundle.module }
    return bundle
  }
}

private struct RelayStringsKey: EnvironmentKey {
  static let defaultValue = RelayStrings()
}

extension EnvironmentValues {
  /// The texts the Relay components read.
  public var relayStrings: RelayStrings {
    get { self[RelayStringsKey.self] }
    set { self[RelayStringsKey.self] = newValue }
  }
}
