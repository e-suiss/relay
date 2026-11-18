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
