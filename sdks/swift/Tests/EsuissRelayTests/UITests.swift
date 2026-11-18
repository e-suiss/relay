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
    func cell(_ channel: String, _ source: RelayPreferenceSource, effective: Bool)
      -> RelayPreferenceCell
    {
      RelayPreferenceCell(
        category: "orders", channel: channel, value: .unset, effective: effective, source: source)
    }
    XCTAssertEqual(
      RelayPreferenceRowState.of(cell("email", .locked, effective: true), permission: .granted),
      .lockedOn)
    XCTAssertEqual(
      RelayPreferenceRowState.of(cell("email", .tenant, effective: false), permission: .granted),
      .adminDisabled
    )
    XCTAssertEqual(
      RelayPreferenceRowState.of(cell("push", .user, effective: true), permission: .denied),
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
    let model = RelayPreferencesModel(
      api: api,
      categories: [RelayCategoryInfo(key: "friends", name: "Friends", messageClass: .social)],
      settings: FixedSettings()
    )
    harness.transport.enqueue("getMyPreferences", .json(200, preferences(digest: "{}")))
    await model.load()
    let cell = try XCTUnwrap(model.preferences?.cells.first)
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
    "cells":[{"category":"friends","channel":"email","value":"unset","effective":true,\
    "source":"class_default"}],"channels":[],"workflows":[],"scope_keys":[],\
    "profile":{"quiet_hours":[],"schedule":[],"dnd_until":null,"quiet_hours_email":false,\
    "digest":\(digest)}}
    """
  }
}
