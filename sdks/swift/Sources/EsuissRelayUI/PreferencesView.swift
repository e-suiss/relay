import EsuissRelay
import SwiftUI

// X-32
// PC-18
/// The preference centre: one section per category with a row per channel. Locked, administrator
/// and device states are shown in words, and turning a digest category off asks three choices.
public struct RelayPreferencesView: View {
  @ObservedObject var model: RelayPreferencesModel
  @Environment(\.relayTheme) private var theme
  @Environment(\.relayStrings) private var strings
  @Environment(\.openURL) private var openURL
  let openSettings: (() -> Void)?
  let requestPermission: (() -> Void)?

  public init(
    model: RelayPreferencesModel,
    openSettings: (() -> Void)? = nil,
    requestPermission: (() -> Void)? = nil
  ) {
    self.model = model
    self.openSettings = openSettings
    self.requestPermission = requestPermission
  }

  public var body: some View {
    List {
      if let preferences = model.preferences {
        ForEach(preferences.categories, id: \.self) { category in
          Section(header: Text(model.name(of: category))) {
            ForEach(preferences.cells(for: category), id: \.self) { cell in
              row(cell)
            }
          }
        }
      }
    }
    .navigationTitle(strings.text("prefs.title"))
    .task { await model.load() }
    .confirmationDialog(
      strings.text("prefs.offPrompt"),
      isPresented: Binding(
        get: { model.pendingTurnOff != nil },
        set: { presented in if !presented { model.pendingTurnOff = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button(strings.text("prefs.instant")) { Task { await model.choose(.instant) } }
      Button(strings.text("prefs.digest")) { Task { await model.choose(.digest) } }
      Button(strings.text("prefs.never")) { Task { await model.choose(.never) } }
      Button(strings.text("prefs.cancel"), role: .cancel) { model.pendingTurnOff = nil }
    }
  }

  @ViewBuilder private func row(_ cell: RelayPreferenceCell) -> some View {
    let state = model.state(of: cell)
    let name = strings.channelName(cell.channel)
    switch state {
    case .on, .off:
      Toggle(
        name,
        isOn: Binding(
          get: { state == .on },
          set: { value in Task { await model.set(cell, on: value) } }
        )
      )
      .tint(theme.accent)
      .accessibilityValue(Text(strings.text(state == .on ? "prefs.on" : "prefs.off")))
    case .lockedOn:
      LabeledContent(name, value: strings.text("prefs.lockedOn"))
    case .adminDisabled:
      LabeledContent(name, value: strings.text("prefs.adminDisabled"))
    case .deviceDisabled:
      HStack {
        LabeledContent(name, value: strings.text("prefs.deviceDisabled"))
        if let openSettings {
          Button(strings.text("prefs.openSettings"), action: openSettings)
        }
      }
    case .permissionPending:
      HStack {
        LabeledContent(name, value: strings.text("prefs.permissionPending"))
        if let requestPermission {
          Button(strings.text("prefs.allow"), action: requestPermission)
        }
      }
    }
  }
}

/// Opens the preference centre when iOS asks for the app's notification settings
/// (`providesAppNotificationSettings`).
@MainActor
public final class RelayPreferencesRouter: ObservableObject {
  @Published public var isPresented = false

  public init() {}

  public func open() {
    isPresented = true
  }
}

extension View {
  /// Presents the preference centre when the router opens it.
  public func relayPreferencesSheet(
    router: RelayPreferencesRouter,
    model: RelayPreferencesModel
  ) -> some View {
    modifier(RelayPreferencesSheet(router: router, model: model))
  }
}

private struct RelayPreferencesSheet: ViewModifier {
  @ObservedObject var router: RelayPreferencesRouter
  let model: RelayPreferencesModel

  func body(content: Content) -> some View {
    content.sheet(isPresented: $router.isPresented) {
      NavigationStack {
        RelayPreferencesView(model: model)
      }
    }
  }
}
