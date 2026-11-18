import Foundation
import XCTest

@testable import EsuissRelay
@testable import EsuissRelayUI

final class UITests: XCTestCase {
  func testX32TurkishAndEnglishTextsCoverTheSameKeys() throws {
    let resources = Fixtures.repositoryRoot.appendingPathComponent(
      "sdks/swift/Sources/EsuissRelayUI/Resources"
    )
    let english = try keys(resources.appendingPathComponent("en.lproj/Localizable.strings"))
    let turkish = try keys(resources.appendingPathComponent("tr.lproj/Localizable.strings"))
    XCTAssertFalse(english.isEmpty)
    XCTAssertEqual(english, turkish)
    let tr = RelayStrings(locale: Locale(identifier: "tr_TR"))
    let en = RelayStrings(locale: Locale(identifier: "en_US"))
    XCTAssertEqual(tr.text("prefs.lockedOn"), "Açık (kilitli)")
    XCTAssertEqual(en.text("prefs.lockedOn"), "On (locked)")
    XCTAssertEqual(tr.bellLabel(unseen: 3), "Bildirimler, 3 yeni")
    XCTAssertEqual(en.bellLabel(unseen: 0), "Notifications")
    XCTAssertEqual(tr.channelName("email"), "E-posta")
    XCTAssertEqual(RelayStrings(locale: Locale(identifier: "de_DE")).text("prefs.never"), "Never")
    for status in RelayConsentStatus.allCases {
      XCTAssertTrue(english.contains("consent.status.\(status.rawValue)"))
    }
    for key in [
      "inbox.agent", "inbox.waitpoint.awaiting", "inbox.waitpoint.processing",
      "inbox.waitpoint.responded", "inbox.waitpoint.respondedBySubscriber",
      "inbox.waitpoint.respondedByAgent", "inbox.waitpoint.notAwaited", "inbox.approval.open",
      "inbox.approval.hint", "consent.title", "consent.readOnly", "consent.manage",
    ] {
      XCTAssertTrue(english.contains(key), key)
      XCTAssertNotEqual(tr.text(key), key)
      XCTAssertNotEqual(en.text(key), key)
    }
    XCTAssertEqual(tr.text("inbox.agent"), "Yapay zekâ ajanı")
    XCTAssertEqual(en.text("consent.status.pending_iys"), "Waiting for İYS registration")
  }

  func testAG35WaitpointStatesAreShownInWords() {
    let en = RelayStrings(locale: Locale(identifier: "en_US"))
    let tr = RelayStrings(locale: Locale(identifier: "tr_TR"))
    var waitpoint = RelayWaitpoint(id: "wp_1", subjectDigest: "d", options: [.init(label: "Yes", value: "yes")])
    XCTAssertEqual(en.waitpointStatus(waitpoint), "Waiting for your response")
    waitpoint.status = .processing
    XCTAssertEqual(tr.waitpointStatus(waitpoint), "Yanıt işleniyor")
    waitpoint.status = .notAwaited
    XCTAssertEqual(en.waitpointStatus(waitpoint), "No longer awaiting a response")
    waitpoint.status = .responded
    XCTAssertEqual(en.waitpointStatus(waitpoint), "Answered")
    waitpoint.responder = .init(kind: .agent, recipientId: "rcp_1")
    waitpoint.respondedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let responded = en.waitpointStatus(waitpoint)
    XCTAssertTrue(responded.hasPrefix("Answered by an AI agent · "))
    XCTAssertTrue(tr.waitpointStatus(waitpoint).hasPrefix("Bir yapay zekâ ajanı yanıtladı · "))
  }

  @MainActor
  func testX44PC59ConsentsAreReadOnlyBesideThePreferences() async throws {
    let harness = Harness()
    let api = RelayPreferencesAPI(http: harness.http)
    let model = RelayPreferencesModel(
      api: api,
      settings: FixedSettings(),
      consentManagementURL: URL(string: "https://access.test/consents"),
      brandNames: ["stn_01j9zq3k4m5n6p7q8r9s0t1v2w": "Shop"]
    )
    harness.transport.enqueue("getMyPreferences", .json(200, preferences(digest: "{}")))
    harness.transport.enqueue(
      "listMyConsents",
      .json(
        200,
        """
        {"object":"list","data":[{"object":"consent","id":"cns_01j9zq3k4m5n6p7q8r9s0t1v2w",\
        "brand":"stn_01j9zq3k4m5n6p7q8r9s0t1v2w","channel":"email","status":"active",\
        "consent_kind":"explicit_opt_in","recipient_type":"individual","source":"web",\
        "occurred_at":"2026-11-01T09:30:00Z"},{"object":"consent",\
        "id":"cns_01j9zq3k4m5n6p7q8r9s0t1v2x","brand":null,"channel":"sms",\
        "status":"pending_iys","consent_kind":null,"recipient_type":null,"source":"store",\
        "occurred_at":"2026-10-01T09:30:00Z"}],"has_more":false,"next_cursor":null,\
        "previous_cursor":null}
        """
      )
    )
    await model.load()
    XCTAssertEqual(model.consents.count, 2)
    XCTAssertEqual(model.consents[0].status, .active)
    XCTAssertEqual(model.consents[0].kind, "explicit_opt_in")
    XCTAssertEqual(model.brandName(of: model.consents[0]), "Shop")
    XCTAssertEqual(model.consents[1].status, .pendingIys)
    XCTAssertNil(model.brandName(of: model.consents[1]))
    XCTAssertEqual(model.consentManagementURL, URL(string: "https://access.test/consents"))
    XCTAssertNotNil(model.preferences)
    let request = try XCTUnwrap(harness.transport.requests("listMyConsents").first)
    XCTAssertEqual(request.request.method, .get)
    XCTAssertEqual(request.request.path, "/v1/subscriber/consents?limit=100")
    XCTAssertTrue(harness.transport.requests("updateMyPreferences").isEmpty)
  }

  @MainActor
  func testX44PreferencesStillShowWhenConsentsCannotBeRead() async {
    let harness = Harness()
    let model = RelayPreferencesModel(
      api: RelayPreferencesAPI(http: harness.http), settings: FixedSettings())
    harness.transport.enqueue("getMyPreferences", .json(200, preferences(digest: "{}")))
    harness.transport.enqueue("listMyConsents", .problem(403, code: "auth_insufficient_scope"))
    await model.load()
    XCTAssertNotNil(model.preferences)
    XCTAssertTrue(model.consents.isEmpty)
    XCTAssertNil(model.lastError)
    XCTAssertNil(model.consentManagementURL)
  }

  func testPC15PC16X51RowStates() {
    func cell(
      _ channel: String, _ source: RelayPreferenceSource, effective: Bool, locked: Bool = false,
      admin: Bool = false, device: Bool = false
    ) -> RelayPreferenceCell {
      RelayPreferenceCell(
        category: "orders", channel: channel, value: .unset, effective: effective, source: source,
        locked: locked, lockBeneficiary: locked ? .subscriber : nil, disabledByAdmin: admin,
        disabledInDeviceSettings: device)
    }
    XCTAssertEqual(
      RelayPreferenceRowState.of(
        cell("email", .locked, effective: true, locked: true), permission: .granted),
      .lockedOn)
    XCTAssertEqual(
      RelayPreferenceRowState.of(
        cell("email", .tenant, effective: false, admin: true), permission: .granted),
      .adminDisabled
    )
    XCTAssertEqual(
      RelayPreferenceRowState.of(cell("email", .tenant, effective: false), permission: .granted),
      .off
    )
    XCTAssertEqual(
      RelayPreferenceRowState.of(cell("push", .user, effective: true), permission: .denied),
      .deviceDisabled
    )
    XCTAssertEqual(
      RelayPreferenceRowState.of(
        cell("web_push", .user, effective: true, device: true), permission: .granted),
      .deviceDisabled
    )
    XCTAssertEqual(
      RelayPreferenceRowState.of(
        cell("push", .classDefault, effective: true), permission: .notDetermined),
      .permissionPending
    )
    XCTAssertEqual(
      RelayPreferenceRowState.of(cell("sms", .user, effective: false), permission: .denied), .off)
    XCTAssertTrue(RelayPreferenceRowState.on.isEditable)
    XCTAssertFalse(RelayPreferenceRowState.lockedOn.isEditable)
  }

  @MainActor
  func testPC17TurningADigestCategoryOffAsksThreeChoicesFirst() async throws {
    let harness = Harness()
    let api = RelayPreferencesAPI(http: harness.http)
    let model = RelayPreferencesModel(api: api, settings: FixedSettings())
    harness.transport.enqueue("getMyPreferences", .json(200, preferences(digest: "{}")))
    await model.load()
    let cell = try XCTUnwrap(model.preferences?.cells.first)
    XCTAssertTrue(cell.digestAllowed)
    XCTAssertEqual(model.name(of: "friends"), "Friends")
    await model.set(cell, on: false)
    XCTAssertEqual(model.pendingTurnOff, cell)
    XCTAssertTrue(harness.transport.requests("updateMyPreferences").isEmpty)
    harness.transport.enqueue(
      "updateMyPreferences", .json(200, preferences(digest: "{\"friends\":\"digest\"}")))
    await model.choose(.digest)
    let body = try XCTUnwrap(harness.transport.requests("updateMyPreferences").first).json
    let profile = try XCTUnwrap(body["profile"] as? [String: Any])
    XCTAssertEqual(profile["digest"] as? [String: String], ["friends": "digest"])
    XCTAssertNil(body["preferences"])
    XCTAssertEqual(model.preferences?.digest["friends"], .digest)
  }

  @MainActor
  func testX31PreferenceWriteSendsOnlyTheCell() async throws {
    let harness = Harness()
    let api = RelayPreferencesAPI(http: harness.http)
    harness.transport.enqueue("updateMyPreferences", .json(200, preferences(digest: "{}")))
    _ = try await api.set(category: "friends", channel: "email", value: .optOut)
    let body = try XCTUnwrap(harness.transport.requests("updateMyPreferences").first).json
    XCTAssertNil(body["profile"])
    let writes = try XCTUnwrap(body["preferences"] as? [[String: Any]])
    XCTAssertEqual(writes.first?["level"] as? String, "category_channel")
    XCTAssertEqual(writes.first?["value"] as? String, "opt_out")
  }

  @MainActor
  func testX51CellCarriesLockAdministratorAndDeviceStates() async throws {
    let harness = Harness()
    let api = RelayPreferencesAPI(http: harness.http)
    let model = RelayPreferencesModel(api: api, settings: FixedSettings())
    harness.transport.enqueue("getMyPreferences", .json(200, preferences(digest: "{}")))
    await model.load()
    let cells = try XCTUnwrap(model.preferences?.cells)
    XCTAssertEqual(cells.count, 4)
    XCTAssertEqual(cells[1].categoryName, "Sign-in alerts")
    XCTAssertTrue(cells[1].locked)
    XCTAssertEqual(cells[1].lockBeneficiary, .subscriber)
    XCTAssertEqual(model.state(of: cells[1]), .lockedOn)
    XCTAssertTrue(cells[2].disabledByAdmin)
    XCTAssertEqual(model.state(of: cells[2]), .adminDisabled)
    XCTAssertTrue(cells[3].disabledInDeviceSettings)
    XCTAssertEqual(model.state(of: cells[3]), .deviceDisabled)
    XCTAssertNil(cells[0].lockBeneficiary)
    XCTAssertEqual(model.state(of: cells[0]), .on)
  }

  private func keys(_ url: URL) throws -> Set<String> {
    let text = try String(contentsOf: url, encoding: .utf8)
    return Set(
      text.split(separator: "\n").compactMap { line -> String? in
        guard line.hasPrefix("\""), let end = line.dropFirst().firstIndex(of: "\"") else {
          return nil
        }
        return String(line[line.index(after: line.startIndex)..<end])
      }
    )
  }

  private func preferences(digest: String) -> String {
    """
    {"object":"subscriber_preferences","subscriber_id":"sub_01j9zq3k4m5n6p7q8r9s0t1v2w",\
    "cells":[{"category":"friends","category_name":"Friends","channel":"email",\
    "value":"unset","effective":true,"source":"class_default","locked":false,\
    "lock_beneficiary":null,"disabled_by_admin":false,"disabled_in_device_settings":false,\
    "digest_allowed":true},\
    {"category":"sign_in","category_name":"Sign-in alerts","channel":"email",\
    "value":"unset","effective":true,"source":"locked","locked":true,\
    "lock_beneficiary":"subscriber","disabled_by_admin":false,\
    "disabled_in_device_settings":false,"digest_allowed":false},\
    {"category":"offers","category_name":"Offers","channel":"sms","value":"opt_out",\
    "effective":false,"source":"tenant","locked":false,"lock_beneficiary":null,\
    "disabled_by_admin":true,"disabled_in_device_settings":false,"digest_allowed":false},\
    {"category":"friends","category_name":"Friends","channel":"web_push","value":"unset",\
    "effective":true,"source":"class_default","locked":false,"lock_beneficiary":null,\
    "disabled_by_admin":false,"disabled_in_device_settings":true,"digest_allowed":true}],\
    "channels":[],"workflows":[],"scope_keys":[],\
    "profile":{"quiet_hours":[],"schedule":[],"dnd_until":null,"quiet_hours_email":false,\
    "digest":\(digest)}}
    """
  }
}
