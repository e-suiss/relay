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

// X-51
/// Whom the lock of a locked category serves (PC-6).
public enum RelayLockBeneficiary: String, Sendable, Equatable {
  case subscriber
  case tenant
}

// PC-6
// PC-15
// PC-16
// PC-17
// X-51
/// One category × channel cell.
public struct RelayPreferenceCell: Equatable, Hashable, Sendable {
  public let category: String
  public let categoryName: String
  public let channel: String
  public let value: RelayPreferenceValue
  public let effective: Bool
  public let source: RelayPreferenceSource
  public let locked: Bool
  public let lockBeneficiary: RelayLockBeneficiary?
  public let disabledByAdmin: Bool
  public let disabledInDeviceSettings: Bool
  public let digestAllowed: Bool

  public init(
    category: String,
    categoryName: String? = nil,
    channel: String,
    value: RelayPreferenceValue,
    effective: Bool,
    source: RelayPreferenceSource,
    locked: Bool = false,
    lockBeneficiary: RelayLockBeneficiary? = nil,
    disabledByAdmin: Bool = false,
    disabledInDeviceSettings: Bool = false,
    digestAllowed: Bool = false
  ) {
    self.category = category
    self.categoryName = categoryName ?? category
    self.channel = channel
    self.value = value
    self.effective = effective
    self.source = source
    self.locked = locked
    self.lockBeneficiary = lockBeneficiary
    self.disabledByAdmin = disabledByAdmin
    self.disabledInDeviceSettings = disabledInDeviceSettings
    self.digestAllowed = digestAllowed
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

// X-44
/// The status of a commercial consent as Access records it.
public enum RelayConsentStatus: String, Sendable, Equatable, CaseIterable {
  case notGiven = "none"
  case pending
  case pendingIys = "pending_iys"
  case active
  case revoked
  case expired
}

// X-44
// PC-59
/// A read-only copy of one commercial consent of the subscriber for a brand and channel.
public struct RelayConsent: Identifiable, Equatable, Hashable, Sendable {
  public let id: String
  public let brand: String?
  public let channel: String
  public let status: RelayConsentStatus
  public let kind: String?
  public let recipientType: String?
  public let source: String
  public let occurredAt: Date

  public init(
    id: String,
    brand: String? = nil,
    channel: String,
    status: RelayConsentStatus,
    kind: String? = nil,
    recipientType: String? = nil,
    source: String,
    occurredAt: Date
  ) {
    self.id = id
    self.brand = brand
    self.channel = channel
    self.status = status
    self.kind = kind
    self.recipientType = recipientType
    self.source = source
    self.occurredAt = occurredAt
  }
}

/// A page of consents.
public struct RelayConsentPage: Equatable, Sendable {
  public let consents: [RelayConsent]
  public let hasMore: Bool
  public let nextCursor: String?
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
      guard case .ok(let ok) = output else { throw RelayError.invalidResponse("getMyPreferences") }
      return RelayPreferences(try ok.body.json)
    }
  }

  // X-44
  // PC-59
  /// A page of the subscriber's commercial consents, newest first. It is a read-only copy of what
  /// Access holds; consent is changed in Access, never through Relay.
  public func consents(limit: Int? = nil, startingAfter: String? = nil) async throws
    -> RelayConsentPage
  {
    try await http.perform(scope: .preferences) { client in
      let output = try await client.listMyConsents(
        .init(query: .init(limit: limit, startingAfter: startingAfter))
      )
      guard case .ok(let ok) = output else { throw RelayError.invalidResponse("listMyConsents") }
      let list = try ok.body.json
      return RelayConsentPage(
        consents: (list.value2.data ?? []).map(RelayConsent.init),
        hasMore: list.value1.hasMore,
        nextCursor: list.value1.nextCursor
      )
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
        preferences: [
          .init(channel: channelValue, level: .channel, value: RelayPreferences.wire(value))
        ]
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
      guard case .ok(let ok) = output else {
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
          categoryName: cell.categoryName,
          channel: cell.channel.rawValue,
          value: RelayPreferenceValue(rawValue: cell.value.rawValue) ?? .unset,
          effective: cell.effective,
          source: RelayPreferenceSource(rawValue: cell.source.rawValue) ?? .classDefault,
          locked: cell.locked,
          lockBeneficiary: cell.lockBeneficiary.flatMap {
            RelayLockBeneficiary(rawValue: $0.rawValue)
          },
          disabledByAdmin: cell.disabledByAdmin,
          disabledInDeviceSettings: cell.disabledInDeviceSettings,
          digestAllowed: cell.digestAllowed
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

extension RelayConsent {
  init(_ consent: Components.Schemas.Consent) {
    self.init(
      id: consent.id,
      brand: consent.brand,
      channel: consent.channel.rawValue,
      status: RelayConsentStatus(rawValue: consent.status.rawValue) ?? .notGiven,
      kind: consent.consentKind?.rawValue,
      recipientType: consent.recipientType?.rawValue,
      source: consent.source,
      occurredAt: consent.occurredAt
    )
  }
}
