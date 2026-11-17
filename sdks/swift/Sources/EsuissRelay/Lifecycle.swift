import Foundation

#if canImport(UIKit)
  import UIKit
#endif

/// The steps the lifecycle runs; `RelayClient` implements them and tests record their order.
public protocol RelayLifecycleSteps: Sendable {
  func refreshCounters() async
  func connectRealtime() async
  func synchronize() async
  func drainQueue() async
  func disconnectRealtime() async
}

// IN-35
/// The mobile lifecycle: the background closes the realtime connection; the foreground asks for the
/// counters (the badge is right at once), connects, runs a delta or cold sync, and drains the offline
/// queue last so it causes no needless `409`.
public actor RelayLifecycle {
  private let steps: any RelayLifecycleSteps
  private var inForeground = false

  public init(steps: any RelayLifecycleSteps) {
    self.steps = steps
  }

  public func enterForeground() async {
    guard !inForeground else { return }
    inForeground = true
    await steps.refreshCounters()
    await steps.connectRealtime()
    await steps.synchronize()
    await steps.drainQueue()
  }

  public func enterBackground() async {
    guard inForeground else { return }
    inForeground = false
    await steps.disconnectRealtime()
  }
}

/// Forwards the app's foreground and background notifications to a `RelayLifecycle`.
public final class RelayLifecycleObserver: @unchecked Sendable {
  private let center: NotificationCenter
  private var tokens: [NSObjectProtocol] = []

  public init(lifecycle: RelayLifecycle, center: NotificationCenter = .default) {
    self.center = center
    #if canImport(UIKit) && !os(watchOS)
      tokens.append(
        center.addObserver(
          forName: UIApplication.willEnterForegroundNotification,
          object: nil,
          queue: nil
        ) { _ in
          Task { await lifecycle.enterForeground() }
        }
      )
      tokens.append(
        center.addObserver(
          forName: UIApplication.didEnterBackgroundNotification,
          object: nil,
          queue: nil
        ) { _ in
          Task { await lifecycle.enterBackground() }
        }
      )
    #endif
  }

  deinit {
    for token in tokens { center.removeObserver(token) }
  }
}
