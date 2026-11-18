import EsuissRelay
import SwiftUI

// X-32
/// A bell with the unseen badge; its accessibility label reads the count.
public struct RelayBellButton: View {
  @ObservedObject var store: RelayInboxStore
  @Environment(\.relayTheme) private var theme
  @Environment(\.relayStrings) private var strings
  let action: () -> Void

  public init(store: RelayInboxStore, action: @escaping () -> Void) {
    self.store = store
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      ZStack(alignment: .topTrailing) {
        Image(systemName: "bell")
          .imageScale(.large)
          .foregroundColor(theme.primaryText)
        if store.counters.unseen > 0 {
          Text(store.counters.unseen > 99 ? "99+" : "\(store.counters.unseen)")
            .font(.caption2.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(theme.unreadIndicator))
            .offset(x: 8, y: -8)
        }
      }
      .frame(minWidth: 44, minHeight: 44)
    }
    .accessibilityLabel(Text(strings.bellLabel(unseen: store.counters.unseen)))
  }
}

// X-32
// X-6
/// The inbox list: unread items are marked by a dot, a bold title and their accessibility label, never
/// by colour alone; swipe actions send read, unread, archive and hide intents.
public struct RelayInboxView: View {
  @ObservedObject var store: RelayInboxStore
  @Environment(\.relayTheme) private var theme
  @Environment(\.relayStrings) private var strings
  @Environment(\.openURL) private var openURL

  public init(store: RelayInboxStore) {
    self.store = store
  }

  public var body: some View {
    List {
      if store.items.isEmpty, !store.isLoading {
        Text(strings.text("inbox.empty"))
          .foregroundColor(theme.secondaryText)
          .frame(maxWidth: .infinity, alignment: .center)
          .accessibilityAddTraits(.isStaticText)
      }
      ForEach(store.items) { item in
        RelayInboxRow(item: item)
          .contentShape(Rectangle())
          .onTapGesture { open(item) }
          .accessibilityAddTraits(.isButton)
          .onAppear { Task { await store.markSeen([item]) } }
          .swipeActions(edge: .leading) {
            Button(strings.text(item.read ? "inbox.markUnread" : "inbox.markRead")) {
              Task { await store.perform(item.read ? .unread : .read, on: item) }
            }
            .tint(theme.accent)
          }
          .swipeActions(edge: .trailing) {
            Button(strings.text("inbox.hide"), role: .destructive) {
              Task { await store.perform(.hide, on: item) }
            }
            Button(strings.text("inbox.archive")) {
              Task { await store.perform(.archive, on: item) }
            }
          }
      }
      if store.hasMore {
        Button(strings.text("inbox.loadMore")) {
          Task { await store.loadMore() }
        }
      }
    }
    .refreshable { await store.synchronize() }
    .navigationTitle(strings.text("inbox.title"))
    .toolbar {
      ToolbarItem {
        Button(strings.text("inbox.markAllRead")) {
          Task { await store.markAllRead() }
        }
        .disabled(store.counters.unread == 0)
      }
    }
    .overlay(alignment: .bottom) { noticeBanner }
  }

  @ViewBuilder private var noticeBanner: some View {
    if store.notice != nil {
      HStack {
        Text(strings.text("inbox.updatedElsewhere"))
        Spacer()
        Button(strings.text("prefs.cancel")) { store.notice = nil }
      }
      .padding()
      .background(RoundedRectangle(cornerRadius: theme.cornerRadius).fill(.thinMaterial))
      .padding()
      .accessibilityElement(children: .combine)
    }
  }

  private func open(_ item: RelayInboxItem) {
    Task { await store.perform(.click, on: item) }
    if let url = item.url { openURL(url) }
  }
}

/// One inbox row.
public struct RelayInboxRow: View {
  let item: RelayInboxItem
  @Environment(\.relayTheme) private var theme
  @Environment(\.relayStrings) private var strings

  public init(item: RelayInboxItem) {
    self.item = item
  }

  public var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: item.read ? "circle" : "circle.fill")
        .font(.caption)
        .foregroundColor(item.read ? .clear : theme.unreadIndicator)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        if let title = item.title {
          Text(title)
            .font(item.read ? .body : .body.bold())
            .foregroundColor(theme.primaryText)
        }
        if let body = item.body {
          Text(body)
            .font(.subheadline)
            .foregroundColor(theme.secondaryText)
            .lineLimit(3)
        }
        Text(item.lastActivityAt, style: .relative)
          .font(.caption)
          .foregroundColor(theme.secondaryText)
      }
      .environment(\.layoutDirection, item.isRightToLeft ? .rightToLeft : .leftToRight)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityValue(Text(item.read ? "" : strings.text("inbox.unread")))
  }
}
