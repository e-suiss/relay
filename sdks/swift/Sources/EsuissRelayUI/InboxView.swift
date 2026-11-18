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
        RelayInboxRow(item: item, respond: responder(for: item))
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

  private func responder(for item: RelayInboxItem) -> (RelayWaitpoint.Option) -> Void {
    { [store] option in Task { await store.respond(to: item, with: option) } }
  }
}

// X-6
// AG-34
// AG-35
/// One inbox row: an agent's item carries the agent label, and an item with a waitpoint shows its
/// state; answer buttons appear only while a response is awaited, and an approval item only links
/// to the Access approval surface.
public struct RelayInboxRow: View {
  let item: RelayInboxItem
  let respond: ((RelayWaitpoint.Option) -> Void)?
  @Environment(\.relayTheme) private var theme
  @Environment(\.relayStrings) private var strings

  public init(item: RelayInboxItem, respond: ((RelayWaitpoint.Option) -> Void)? = nil) {
    self.item = item
    self.respond = respond
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      content
      RelayWaitpointView(item: item, respond: respond)
        .padding(.leading, 24)
    }
    .padding(.vertical, 4)
  }

  private var content: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: item.read ? "circle" : "circle.fill")
        .font(.caption)
        .foregroundColor(item.read ? .clear : theme.unreadIndicator)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        if item.senderType == .agent {
          Text(strings.text("inbox.agent"))
            .font(.caption.bold())
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Capsule().stroke(theme.secondaryText, lineWidth: 1))
        }
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
    .accessibilityElement(children: .combine)
    .accessibilityValue(Text(item.read ? "" : strings.text("inbox.unread")))
  }
}

// AG-35
// IN-6
// AG-32
/// The waitpoint state of an inbox item: the options as buttons while a response is awaited, then
/// processing, who responded and when, or that no response is awaited any more. An approval item
/// shows only the link to the Access approval surface and is never answered here.
public struct RelayWaitpointView: View {
  let item: RelayInboxItem
  let respond: ((RelayWaitpoint.Option) -> Void)?
  @Environment(\.relayTheme) private var theme
  @Environment(\.relayStrings) private var strings

  public init(item: RelayInboxItem, respond: ((RelayWaitpoint.Option) -> Void)? = nil) {
    self.item = item
    self.respond = respond
  }

  public var body: some View {
    if item.isApprovalRequest {
      approval
    } else if let waitpoint = item.waitpoint {
      response(waitpoint)
    }
  }

  @ViewBuilder private var approval: some View {
    if let waitpoint = item.waitpoint, waitpoint.isClosed {
      status(strings.waitpointStatus(waitpoint))
    } else if let url = item.approvalURL {
      Link(strings.text("inbox.approval.open"), destination: url)
        .buttonStyle(.bordered)
        .tint(theme.accent)
        .frame(minHeight: 44)
        .accessibilityHint(Text(strings.text("inbox.approval.hint")))
    }
  }

  @ViewBuilder private func response(_ waitpoint: RelayWaitpoint) -> some View {
    if item.isAnswerable, let respond {
      VStack(alignment: .leading, spacing: 4) {
        status(strings.waitpointStatus(waitpoint))
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(waitpoint.options, id: \.self) { option in
              Button(option.label) { respond(option) }
                .buttonStyle(.bordered)
                .tint(theme.accent)
                .frame(minHeight: 44)
            }
          }
        }
      }
    } else {
      status(strings.waitpointStatus(waitpoint))
    }
  }

  private func status(_ text: String) -> some View {
    Text(text)
      .font(.footnote)
      .foregroundColor(theme.secondaryText)
      .accessibilityAddTraits(.isStaticText)
  }
}

extension RelayStrings {
  // AG-35
  /// The words for a waitpoint state; a responded waitpoint says who responded and when.
  public func waitpointStatus(_ waitpoint: RelayWaitpoint) -> String {
    switch waitpoint.status {
    case .awaiting:
      return text("inbox.waitpoint.awaiting")
    case .processing:
      return text("inbox.waitpoint.processing")
    case .notAwaited:
      return text("inbox.waitpoint.notAwaited")
    case .responded:
      let who: String
      switch waitpoint.responder?.kind {
      case .subscriber: who = text("inbox.waitpoint.respondedBySubscriber")
      case .agent: who = text("inbox.waitpoint.respondedByAgent")
      case nil: who = text("inbox.waitpoint.responded")
      }
      guard let respondedAt = waitpoint.respondedAt else { return who }
      let when = respondedAt.formatted(
        Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
      )
      return "\(who) · \(when)"
    }
  }
}
