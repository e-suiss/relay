package app.suiss.relay

import android.app.NotificationManager
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.util.Locale
import java.util.TimeZone

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class PushTest {
    private val context: Context = ApplicationProvider.getApplicationContext()

    @Test
    fun `CH-28 registration carries permission, channel importances and the replaced token`() =
        runBlocking<Unit> {
            val harness = Harness()
            val storage = MemoryDeviceStorage(RelayDeviceRecord(Fixtures.DEVICE_ID, "old-token"))
            val push =
                RelayPushApi(harness.http, storage, { RelayNotificationSettings(RelayPermission.DENIED) }) {
                    listOf("relay.orders.active" to "default", "relay.orders.passive" to "low")
                }
            harness.server.enqueue("POST /v1/subscriber/devices", Reply.json(201, Fixtures.device()))
            assertEquals(Fixtures.DEVICE_ID, push.register("new-token"))
            val body = harness.server.requests("POST /v1/subscriber/devices").single().json
            assertEquals("fcm", body.get("platform").asString)
            assertEquals("new-token", body.get("token").asString)
            assertEquals("denied", body.get("permission").asString)
            assertEquals("app.suiss.example", body.get("app").asString)
            assertEquals("old-token", body.get("previous_token").asString)
            val channels =
                body.getAsJsonArray("android_channels").map {
                    it.asJsonObject.get("id").asString to
                        it.asJsonObject.get("importance").asString
                }
            assertEquals(setOf("relay.orders.active" to "default", "relay.orders.passive" to "low"), channels.toSet())
            assertNull(body.get("apns_environment"))
            assertEquals(RelayDeviceRecord(Fixtures.DEVICE_ID, "new-token"), storage.load())
        }

    @Test
    fun `CH-31 refresh sends the same token without a previous token`() =
        runBlocking<Unit> {
            val harness = Harness()
            val storage = MemoryDeviceStorage(RelayDeviceRecord(Fixtures.DEVICE_ID, "token"))
            val push = RelayPushApi(harness.http, storage, { RelayNotificationSettings(RelayPermission.GRANTED) }) { emptyList() }
            harness.server.enqueue("POST /v1/subscriber/devices", Reply.json(200, Fixtures.device()))
            push.refreshRegistration()
            val body = harness.server.requests("POST /v1/subscriber/devices").single().json
            assertEquals("token", body.get("token").asString)
            assertNull(body.get("previous_token"))
            assertNull(body.get("android_channels"))
        }

    @Test
    fun `CH-31 unregister disables the device and forgets it`() =
        runBlocking<Unit> {
            val harness = Harness()
            val storage = MemoryDeviceStorage(RelayDeviceRecord(Fixtures.DEVICE_ID, "token"))
            val push = RelayPushApi(harness.http, storage, { RelayNotificationSettings(RelayPermission.GRANTED) }) { emptyList() }
            harness.server.enqueue("DELETE /v1/subscriber/devices/${Fixtures.DEVICE_ID}", Reply.json(200, Fixtures.device()))
            push.unregister()
            assertNull(storage.load())
            assertNotNull(harness.server.requests("DELETE /v1/subscriber/devices/${Fixtures.DEVICE_ID}").single().header("Idempotency-Key"))
        }

    @Test
    fun `CH-32 a receipt names the delivery`() =
        runBlocking<Unit> {
            val harness = Harness()
            val push =
                RelayPushApi(harness.http, MemoryDeviceStorage(), { RelayNotificationSettings(RelayPermission.GRANTED) }) { emptyList() }
            harness.server.enqueue(
                "POST /v1/subscriber/push_receipts",
                Reply.json(202, """{"object":"push_receipt","delivery_id":"${Fixtures.DELIVERY_ID}","receipt":"clicked"}"""),
            )
            push.record(RelayReceipt.CLICKED, Fixtures.DELIVERY_ID)
            val request = harness.server.requests("POST /v1/subscriber/push_receipts").single()
            assertEquals(Fixtures.DELIVERY_ID, request.json.get("delivery_id").asString)
            assertEquals("clicked", request.json.get("receipt").asString)
            assertNotNull(request.header("Idempotency-Key"))
        }

    @Test
    fun `IN-47 status signals carry a time to live and IN-48 are never logged`() =
        runBlocking<Unit> {
            val harness = Harness()
            val storage = MemoryDeviceStorage(RelayDeviceRecord(Fixtures.DEVICE_ID, "token"))
            val push = RelayPushApi(harness.http, storage, { RelayNotificationSettings(RelayPermission.GRANTED) }) { emptyList() }
            harness.server.enqueue(
                "PATCH /v1/subscriber/devices/${Fixtures.DEVICE_ID}/status",
                Reply.json(
                    200,
                    """{"object":"device_status","device_id":"${Fixtures.DEVICE_ID}","version":"v1","signals":""" +
                        """{"worn":true,"locked":"unknown","headphones":"unknown","focus":"unknown","break":"unknown"}}""",
                ),
            )
            push.updateStatus(mapOf(RelayDeviceSignal.WORN to true, RelayDeviceSignal.BREAK to false), ttlSeconds = 2_000)
            val body = harness.server.requests("PATCH /v1/subscriber/devices/${Fixtures.DEVICE_ID}/status").single().json
            val signals = body.getAsJsonObject("signals")
            assertTrue(signals.get("worn").asBoolean)
            assertFalse(signals.get("break").asBoolean)
            assertNull(signals.get("locked"))
            assertEquals("PT900S", body.get("ttl").asString)
            assertEquals("v1", body.get("version").asString)
            harness.logger.messages.forEach {
                assertFalse(it.contains("worn"))
                assertFalse(it.contains("true"))
                assertFalse(it.contains("false"))
            }
        }

    @Test(expected = RelayException.NotRegistered::class)
    fun `IN-47 status needs a registered device`() =
        runBlocking<Unit> {
            val harness = Harness()
            RelayPushApi(harness.http, MemoryDeviceStorage(), { RelayNotificationSettings(RelayPermission.GRANTED) }) { emptyList() }
                .updateStatus(mapOf(RelayDeviceSignal.LOCKED to true))
        }

    @Test
    fun `CH-30 CH-65 channel ids are stable per category and level`() {
        assertEquals("relay.orders.time-sensitive", RelayNotificationChannels.channelId("orders", RelayInterruptionLevel.TIME_SENSITIVE))
        val security = RelayNotificationChannels.specs(RelayCategoryInfo("login", "Login", RelayMessageClass.SECURITY), critical = true)
        assertEquals(
            listOf("relay.login.passive", "relay.login.active", "relay.login.time-sensitive", "relay.login.critical"),
            security.map { it.id },
        )
        assertEquals(
            listOf(
                NotificationManager.IMPORTANCE_LOW,
                NotificationManager.IMPORTANCE_DEFAULT,
                NotificationManager.IMPORTANCE_HIGH,
                NotificationManager.IMPORTANCE_HIGH,
            ),
            security.map { it.importance },
        )
        val marketing = RelayNotificationChannels.specs(RelayCategoryInfo("deals", "Deals", RelayMessageClass.MARKETING))
        assertEquals(listOf("relay.deals.passive"), marketing.map { it.id })
        val social = RelayNotificationChannels.specs(RelayCategoryInfo("friends", "Friends", RelayMessageClass.SOCIAL))
        assertEquals(listOf(NotificationManager.IMPORTANCE_LOW, NotificationManager.IMPORTANCE_LOW), social.map { it.importance })
        assertTrue(RelayNotificationChannels.specs(RelayCategoryInfo("sync", "Sync", RelayMessageClass.SYSTEM)).isEmpty())
    }

    @Test
    fun `CH-30 channels are created once and keep the importance the user chose`() {
        val manager = context.getSystemService(NotificationManager::class.java)
        val categories = listOf(RelayCategoryInfo("orders", "Orders", RelayMessageClass.TRANSACTIONAL))
        RelayNotificationChannels.create(context, categories, { it.wire })
        val active = manager.getNotificationChannel("relay.orders.active")
        assertNotNull(active)
        assertEquals(NotificationManager.IMPORTANCE_DEFAULT, active.importance)
        assertNotNull(manager.getNotificationChannel("relay.general.active"))
        val reported = RelayNotificationChannels.reported(context).toMap()
        assertEquals("default", reported["relay.orders.active"])
        assertEquals("low", reported["relay.orders.passive"])
    }

    @Test
    fun `CH-65 critical needs DND access and the permission is read from the device`() {
        val manager = context.getSystemService(NotificationManager::class.java)
        shadowOf(manager).setNotificationPolicyAccessGranted(false)
        val settings = SystemNotificationSettingsReader(context).read()
        assertFalse(settings.dndAccessGranted)
        shadowOf(manager).setNotificationPolicyAccessGranted(true)
        assertTrue(SystemNotificationSettingsReader(context).read().dndAccessGranted)
    }

    @Test
    fun `CH-33 a content-free push shows the fetched content`() =
        runBlocking<Unit> {
            val harness = Harness()
            val client = harness.client()
            RelayNotificationChannels.create(context, listOf(RelayCategoryInfo("orders", "Orders", RelayMessageClass.TRANSACTIONAL)), {
                it.wire
            })
            harness.server.enqueue("GET /v1/subscriber/inbox/items/${Fixtures.ITEM_ID}", Reply.json(200, Fixtures.item()))
            val shown = client.messaging.handle(mapOf("relay_id" to Fixtures.ITEM_ID))
            assertNotNull(shown)
            assertTrue(shown!!.fetched)
            assertEquals("Order shipped", shown.title)
            assertEquals("relay.orders.active", shown.channelId)
            val manager = context.getSystemService(NotificationManager::class.java)
            assertEquals(1, shadowOf(manager).allNotifications.size)
        }

    @Test
    fun `CH-33 the generic text stays when the content cannot be fetched`() =
        runBlocking<Unit> {
            val harness = Harness()
            val client = harness.client()
            harness.server.enqueue(
                "POST /v1/subscriber/push_receipts",
                Reply.json(202, """{"object":"push_receipt","delivery_id":"${Fixtures.DELIVERY_ID}","receipt":"displayed"}"""),
            )
            val shown =
                client.messaging.handle(
                    mapOf("relay_id" to Fixtures.DELIVERY_ID),
                    Locale.forLanguageTag("tr-TR"),
                )
            assertNotNull(shown)
            assertFalse(shown!!.fetched)
            assertEquals("Yeni bildirim", shown.title)
            assertEquals("Yeni bir bildiriminiz var.", shown.body)
            assertEquals("displayed", harness.server.requests("POST /v1/subscriber/push_receipts").single().json.get("receipt").asString)
            val neutral = client.messaging.handle(mapOf("relay_id" to Fixtures.ITEM_ID, "relay_neutral_title" to "New notification"))
            assertEquals("New notification", neutral?.title)
        }

    @Test
    fun `CH-33 payload parsing`() {
        val payload = RelayPushPayload.from(mapOf("relay_id" to Fixtures.DELIVERY_ID, "relay_topic" to "order-1"))
        assertEquals(Fixtures.DELIVERY_ID, payload?.deliveryId)
        assertNull(payload?.itemId)
        val sync = RelayPushPayload.from(mapOf("sync" to "true", "counter_version" to "12"))
        assertEquals(true, sync?.isSyncSignal)
        assertEquals(12, sync?.counterVersion)
        assertNull(RelayPushPayload.from(mapOf("other" to "x")))
    }

    @Test
    fun `IN-38 read items lose their notifications`() =
        runBlocking<Unit> {
            val harness = Harness()
            val client = harness.client()
            harness.server.enqueue("GET /v1/subscriber/inbox/items/${Fixtures.ITEM_ID}", Reply.json(200, Fixtures.item()))
            client.messaging.handle(mapOf("relay_id" to Fixtures.ITEM_ID))
            val manager = context.getSystemService(NotificationManager::class.java)
            assertEquals(1, shadowOf(manager).allNotifications.size)
            RelayNotificationRemover(context).remove(listOf(RelayInboxItem(id = Fixtures.ITEM_ID, stateVersion = 2)))
            assertEquals(0, shadowOf(manager).allNotifications.size)
        }

    @Test
    fun `CH-28 device context follows the contract patterns`() {
        assertEquals("tr-TR", DeviceContext.locale(Locale.forLanguageTag("tr-TR")))
        assertEquals("Europe/Istanbul", DeviceContext.timeZone(TimeZone.getTimeZone("Europe/Istanbul")))
        assertNull(DeviceContext.timeZone(TimeZone.getTimeZone("GMT")))
    }
}
