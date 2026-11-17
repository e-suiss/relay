import Foundation
import UserNotifications
import XCTest

@testable import EsuissRelay
@testable import EsuissRelayNotificationService

final class PushTests: XCTestCase {
  func testCH28RegistrationCarriesPermissionAndNamesTheReplacedToken() async throws {
    let harness = Harness()
    let storage = MemoryDeviceStorage(RelayDeviceRecord(deviceId: Fixtures.deviceId, token: "old"))
    let push = RelayPushAPI(
      http: harness.http,
      storage: storage,
      settings: FixedSettings(settings: RelayNotificationSettings(permission: .provisional))
    )
    harness.transport.enqueue("registerMyDevice", .json(201, Fixtures.device()))
    let deviceId = try await push.register(apnsToken: Data([0xAB, 0x01]), environment: .sandbox)
    XCTAssertEqual(deviceId, Fixtures.deviceId)
    let body = try XCTUnwrap(harness.transport.requests("registerMyDevice").first).json
    XCTAssertEqual(body["platform"] as? String, "apns")
    XCTAssertEqual(body["token"] as? String, "ab01")
    XCTAssertEqual(body["permission"] as? String, "provisional")
    XCTAssertEqual(body["apns_environment"] as? String, "sandbox")
    XCTAssertEqual(body["app"] as? String, "app.suiss.example")
    XCTAssertEqual(body["previous_token"] as? String, "old")
    XCTAssertEqual(storage.load(), RelayDeviceRecord(deviceId: Fixtures.deviceId, token: "ab01"))
  }

  func testCH31RefreshSendsTheSameTokenWithoutPreviousToken() async throws {
    let harness = Harness()
    let storage = MemoryDeviceStorage(RelayDeviceRecord(deviceId: Fixtures.deviceId, token: "ab01"))
    let push = RelayPushAPI(http: harness.http, storage: storage, settings: FixedSettings())
    harness.transport.enqueue("registerMyDevice", .json(200, Fixtures.device()))
    try await push.refreshRegistration(environment: .production)
    let body = try XCTUnwrap(harness.transport.requests("registerMyDevice").first).json
    XCTAssertEqual(body["token"] as? String, "ab01")
    XCTAssertNil(body["previous_token"])
    XCTAssertEqual(body["permission"] as? String, "granted")
  }

  func testCH32ReceiptNamesTheDelivery() async throws {
    let harness = Harness()
    let push = RelayPushAPI(http: harness.http, storage: MemoryDeviceStorage(), settings: FixedSettings())
    harness.transport.enqueue(
      "recordMyPushReceipt",
      .json(
        202,
        "{\"object\":\"push_receipt\",\"delivery_id\":\"\(Fixtures.deliveryId)\",\"receipt\":\"clicked\"}"
      )
    )
    try await push.record(.clicked, deliveryId: Fixtures.deliveryId)
    let request = try XCTUnwrap(harness.transport.requests("recordMyPushReceipt").first)
    XCTAssertEqual(request.json["delivery_id"] as? String, Fixtures.deliveryId)
    XCTAssertEqual(request.json["receipt"] as? String, "clicked")
    XCTAssertNotNil(request.header("Idempotency-Key"))
  }

  func testIN47StatusSignalsCarryATimeToLiveAndIN48AreNeverLogged() async throws {
    let harness = Harness()
    let storage = MemoryDeviceStorage(RelayDeviceRecord(deviceId: Fixtures.deviceId, token: "ab01"))
    let push = RelayPushAPI(http: harness.http, storage: storage, settings: FixedSettings())
    harness.transport.enqueue(
      "updateMyDeviceStatus",
      .json(
        200,
        """
        {"object":"device_status","device_id":"\(Fixtures.deviceId)","version":"v1","signals":\
        {"worn":true,"locked":"unknown","headphones":"unknown","focus":"unknown","break":"unknown"}}
        """
      )
    )
    try await push.updateStatus([.worn: true, .breakPoint: false], ttl: 2000)
    let request = try XCTUnwrap(harness.transport.requests("updateMyDeviceStatus").first)
    XCTAssertEqual(request.request.path, "/v1/subscriber/devices/\(Fixtures.deviceId)/status")
    let signals = try XCTUnwrap(request.json["signals"] as? [String: Any])
    XCTAssertEqual(signals["worn"] as? Bool, true)
    XCTAssertEqual(signals["break"] as? Bool, false)
    XCTAssertEqual(request.json["ttl"] as? String, "PT900S")
    XCTAssertEqual(request.json["version"] as? String, "v1")
    for message in harness.logger.messages {
      XCTAssertFalse(message.contains("worn"))
      XCTAssertFalse(message.contains("true"))
      XCTAssertFalse(message.contains("false"))
    }
  }

  func testIN47StatusNeedsARegisteredDevice() async {
    let harness = Harness()
    let push = RelayPushAPI(http: harness.http, storage: MemoryDeviceStorage(), settings: FixedSettings())
    do {
      try await push.updateStatus([.locked: true])
      XCTFail("expected notRegistered")
    } catch {
      XCTAssertEqual(error as? RelayError, .notRegistered)
    }
  }

  func testCH31UnregisterDisablesTheDeviceAndForgetsIt() async throws {
    let harness = Harness()
    let storage = MemoryDeviceStorage(RelayDeviceRecord(deviceId: Fixtures.deviceId, token: "ab01"))
    let push = RelayPushAPI(http: harness.http, storage: storage, settings: FixedSettings())
    harness.transport.enqueue("deleteMyDevice", .json(200, Fixtures.device()))
    try await push.unregister()
    XCTAssertNil(storage.load())
    XCTAssertEqual(
      harness.transport.requests("deleteMyDevice").first?.request.path,
      "/v1/subscriber/devices/\(Fixtures.deviceId)"
    )
  }

  func testCH29ProvisionalOnlyForMarketingAndSocial() {
    let quiet = RelayPermissionMapping.authorizationOptions(for: [.marketing, .social])
    XCTAssertTrue(quiet.contains(.provisional))
    let mixed = RelayPermissionMapping.authorizationOptions(for: [.marketing, .transactional])
    XCTAssertFalse(mixed.contains(.provisional))
    let security = RelayPermissionMapping.authorizationOptions(for: [.security], criticalAlerts: true)
    XCTAssertFalse(security.contains(.provisional))
    XCTAssertTrue(security.contains(.criticalAlert))
    XCTAssertTrue(security.contains(.providesAppNotificationSettings))
    XCTAssertFalse(RelayPermissionMapping.authorizationOptions(for: []).contains(.provisional))
  }

  func testCH28PermissionMapping() {
    XCTAssertEqual(RelayPermissionMapping.permission(.authorized), .granted)
    XCTAssertEqual(RelayPermissionMapping.permission(.denied), .denied)
    XCTAssertEqual(RelayPermissionMapping.permission(.provisional), .provisional)
    XCTAssertEqual(RelayPermissionMapping.permission(.notDetermined), .notDetermined)
    XCTAssertEqual(RelayPermissionMapping.state(.enabled), .enabled)
    XCTAssertEqual(RelayPermissionMapping.state(.disabled), .disabled)
    XCTAssertEqual(RelayPermissionMapping.state(.notSupported), .notSupported)
  }

  func testCH33PayloadsOfApnsAndFcm() {
    let apns = RelayPushPayload(userInfo: [
      "aps": ["alert": ["title": "x"]],
      "relay": ["id": Fixtures.deliveryId, "topic": "order-1"],
    ])
    XCTAssertEqual(apns?.deliveryId, Fixtures.deliveryId)
    XCTAssertNil(apns?.itemId)
    XCTAssertEqual(apns?.topic, "order-1")
    let sync = RelayPushPayload(userInfo: ["relay": ["sync": true, "counter_version": 12]])
    XCTAssertEqual(sync?.isSyncSignal, true)
    XCTAssertEqual(sync?.counterVersion, 12)
    let fcm = RelayPushPayload(data: [
      "relay_id": Fixtures.itemId,
      "relay_neutral_title": "Yeni bildirim",
      "relay_neutral_body": "Yeni bir bildiriminiz var.",
    ])
    XCTAssertEqual(fcm?.itemId, Fixtures.itemId)
    XCTAssertEqual(fcm?.neutralTitle, "Yeni bildirim")
    XCTAssertNil(RelayPushPayload(userInfo: ["aps": [:]]))
  }

  func testCH33ContentIsFetchedOrTheGenericTextStays() async {
    let item = RelayInboxItem(
      id: Fixtures.itemId,
      stateVersion: 1,
      createdAt: Date(),
      title: "Order shipped",
      body: "On its way"
    )
    let receipts = Recorder()
    let fetched = RelayNotificationContentFiller(
      resolve: { _ in item },
      receipt: { id in receipts.append(id) }
    )
    let content = UNMutableNotificationContent()
    content.userInfo = ["relay": ["id": Fixtures.deliveryId]]
    let filled = await fetched.fill(content)
    XCTAssertEqual(filled.title, "Order shipped")
    XCTAssertEqual(filled.body, "On its way")
    XCTAssertEqual(receipts.values, [Fixtures.deliveryId])

    let failing = RelayNotificationContentFiller(resolve: { _ in nil }, receipt: { _ in })
    let empty = UNMutableNotificationContent()
    empty.userInfo = ["relay": ["id": Fixtures.itemId]]
    let fallback = await failing.fill(empty, locale: Locale(identifier: "tr_TR"))
    XCTAssertEqual(fallback.title, "Yeni bildirim")
    XCTAssertEqual(fallback.body, "Yeni bir bildiriminiz var.")

    let neutral = UNMutableNotificationContent()
    neutral.title = "New notification"
    neutral.body = "You have a new notification."
    neutral.userInfo = ["relay": ["id": Fixtures.itemId]]
    let kept = await failing.fill(neutral)
    XCTAssertEqual(kept.title, "New notification")
  }

  func testIN38ReadItemsLoseTheirNotifications() async {
    let delivered = FakeDelivered([
      RelayDeliveredNotification(identifier: "a", relayId: Fixtures.itemId, topic: nil),
      RelayDeliveredNotification(identifier: "b", relayId: Fixtures.deliveryId, topic: "order-1"),
      RelayDeliveredNotification(identifier: "c", relayId: "dlv_other", topic: "other"),
    ])
    let remover = RelayNotificationRemover(center: delivered)
    let item = RelayInboxItem(id: Fixtures.itemId, stateVersion: 2, createdAt: Date(), groupKey: "order-1")
    await remover.remove(items: [item])
    XCTAssertEqual(Set(delivered.removed), ["a", "b"])
  }

  func testCH28DeviceContextFollowsTheContractPatterns() {
    XCTAssertEqual(RelayDeviceContext.locale(Locale(identifier: "tr_TR")), "tr-TR")
    XCTAssertEqual(RelayDeviceContext.timeZone(TimeZone(identifier: "Europe/Istanbul")!), "Europe/Istanbul")
    XCTAssertNil(RelayDeviceContext.timeZone(TimeZone(identifier: "GMT")!))
  }
}
