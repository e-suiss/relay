import EsuissRelay
import EsuissRelayUI
import Foundation
import SwiftUI

enum MyBackend {
  static func relaySubscriberToken(refresh: Bool) async throws -> RelaySubscriberToken {
    RelaySubscriberToken(value: refresh ? "fresh" : "cached", expiresAt: Date().addingTimeInterval(900))
  }
}

// #region client
struct Tokens: RelayTokenProvider {
  func subscriberToken(forceRefresh: Bool) async throws -> RelaySubscriberToken {
    try await MyBackend.relaySubscriberToken(refresh: forceRefresh)
  }
}

func makeClient() -> RelayClient {
  RelayClient(
    configuration: RelayConfiguration(
      baseURL: URL(string: "https://relay.example.com")!,
      appIdentifier: Bundle.main.bundleIdentifier ?? "com.example.app",
      tokenProvider: Tokens()
    )
  )
}
// #endregion client

// #region push
func registerPush(client: RelayClient, deviceToken: Data) async throws {
  _ = try await client.push.register(apnsToken: deviceToken, environment: .production)
}
// #endregion push

// #region inbox
struct InboxScreen: View {
  let client: RelayClient

  var body: some View {
    NavigationStack { RelayInboxView(store: client.store) }
      .relayTheme(RelayTheme(accent: .indigo))
  }
}
// #endregion inbox
