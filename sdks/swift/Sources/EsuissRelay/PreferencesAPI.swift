import EsuissRelayAPI
import Foundation

/// A stored preference value; `unset` falls back to the next level.
public enum RelayPreferenceValue: String, Sendable, Equatable {
  case optIn = "opt_in"
  case optOut = "opt_out"
  case unset
}

/// Where the effective value of a cell comes from (PC-12, PC-15).
public enum RelayPreferenceSource: String, Sendable, Equatable {
  case user
  case tenant
  case categoryDefault = "category_default"
  case classDefault = "class_default"
  case locked
}

/// The digest choice of a category (PC-17).
public enum RelayDigestChoice: String, Sendable, Equatable {
  case instant
  case digest
}

/// One category × channel cell.
public struct RelayPreferenceCell: Equatable, Hashable, Sendable {
  public let category: String
  public let channel: String
  public let value: RelayPreferenceValue
  public let effective: Bool
  public let source: RelayPreferenceSource

  public init(
    category: String,
    channel: String,
    value: RelayPreferenceValue,
    effective: Bool,
    source: RelayPreferenceSource
  ) {
    self.category = category
    self.channel = channel
    self.value = value
    self.effective = effective
    self.source = source
  }
}

/// The subscriber's preferences as the components show them.
public struct RelayPreferences: Equatable, Sendable {
  public let cells: [RelayPreferenceCell]
  public let channels: [String: RelayPreferenceValue]
  public let digest: [String: RelayDigestChoice]

  public init(
    cells: [RelayPreferenceCell],
    channels: [String: RelayPreferenceValue] = [:],
    digest: [String: RelayDigestChoice] = [:]
  ) {
    self.cells = cells
    self.channels = channels
    self.digest = digest
  }

  /// The categories in the order the server listed them.
  public var categories: [String] {
    var seen: Set<String> = []
    return cells.compactMap { seen.insert($0.category).inserted ? $0.category : nil }
  }

  public func cells(for category: String) -> [RelayPreferenceCell] {
    cells.filter { $0.category == category }
  }
}

// X-31
/// The subscriber's own preferences (scope `preferences`): category × channel and channel switches
/// and the digest choice. Identity, contact data and consents are never written from the device.
public final class RelayPreferencesAPI: Sendable {
  let http: RelayHTTP

  init(http: RelayHTTP) {
    self.http = http
  }

  public func load() async throws -> RelayPreferences {
    try await http.perform(scope: .preferences) { client in
      let output = try await client.getMyPreferences(.init())
      guard case let .ok(ok) = output else { throw RelayError.invalidResponse("getMyPreferences") }
      return RelayPreferences(try ok.body.json)
    }
  }

  public func set(category: String, channel: String, value: RelayPreferenceValue) async throws
    -> RelayPreferences
  {
    guard let channelValue = Components.Schemas.Channel(rawValue: channel) else {
      throw RelayError.invalidResponse("unknown channel")
    }
    return try await patch(
      .init(
        preferences: [
          .init(
            category: category,
            channel: channelValue,
            level: .categoryChannel,
            value: RelayPreferences.wire(value)
          )
        ]
      )
    )
  }

  public func set(channel: String, value: RelayPreferenceValue) async throws -> RelayPreferences {
    guard let channelValue = Components.Schemas.Channel(rawValue: channel) else {
      throw RelayError.invalidResponse("unknown channel")
    }
    return try await patch(
      .init(
        preferences: [.init(channel: channelValue, level: .channel, value: RelayPreferences.wire(value))]
      )
    )
  }

  // PC-17
  /// Sets the digest choice of one category; the digest map is written as a whole.
  public func setDigest(category: String, choice: RelayDigestChoice, current: RelayPreferences)
    async throws -> RelayPreferences
  {
    var choices: [String: Components.Schemas.DigestChoices.AdditionalPropertiesPayload] = [:]
    for (key, value) in current.digest {
      choices[key] = value == .digest ? .digest : .instant
    }
    choices[category] = choice == .digest ? .digest : .instant
    return try await patch(
      .init(profile: .init(digest: .init(additionalProperties: choices)))
    )
  }

  private func patch(_ body: Components.Schemas.MyPreferencesPatch) async throws -> RelayPreferences
  {
    let key = IdempotencyKey.make(http.configuration.random)
    return try await http.perform(scope: .preferences) { client in
      let output = try await client.updateMyPreferences(
        .init(headers: .init(idempotencyKey: key), body: .json(body))
      )
      guard case let .ok(ok) = output else {
        throw RelayError.invalidResponse("updateMyPreferences")
      }
      return RelayPreferences(try ok.body.json)
    }
  }
}

extension RelayPreferences {
  init(_ preferences: Components.Schemas.SubscriberPreferences) {
    var channels: [String: RelayPreferenceValue] = [:]
    for channel in preferences.channels {
      channels[channel.channel.rawValue] = RelayPreferenceValue(rawValue: channel.value.rawValue)
    }
    var digest: [String: RelayDigestChoice] = [:]
    for (key, value) in preferences.profile.digest.additionalProperties {
      digest[key] = RelayDigestChoice(rawValue: value.rawValue)
    }
    self.init(
      cells: preferences.cells.map { cell in
        RelayPreferenceCell(
          category: cell.category,
          channel: cell.channel.rawValue,
          value: RelayPreferenceValue(rawValue: cell.value.rawValue) ?? .unset,
          effective: cell.effective,
          source: RelayPreferenceSource(rawValue: cell.source.rawValue) ?? .classDefault
        )
      },
      channels: channels,
      digest: digest
    )
  }

  static func wire(_ value: RelayPreferenceValue) -> Components.Schemas.PreferenceValue {
    switch value {
    case .optIn: return .optIn
    case .optOut: return .optOut
    case .unset: return .unset
    }
  }
}
