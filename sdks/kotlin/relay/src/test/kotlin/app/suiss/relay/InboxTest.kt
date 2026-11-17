package app.suiss.relay

import android.app.NotificationManager
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class InboxTest {
    private val context: Context = ApplicationProvider.getApplicationContext()

    @Test
    fun `IN-13 the queue is compacted per item and ordered by client_seq`() =
        runBlocking<Unit> {
            val queue = IntentQueue(MemoryIntentQueueStorage())
            queue.enqueue("inb_a", RelayInboxOperation.READ, 1)
            queue.enqueue("inb_b", RelayInboxOperation.ARCHIVE, 4)
            queue.enqueue("inb_a", RelayInboxOperation.UNREAD, 2)
            val pending = queue.pending()
            assertEquals(listOf("inb_b", "inb_a"), pending.map { it.itemId })
            assertEquals(listOf(RelayInboxOperation.ARCHIVE, RelayInboxOperation.UNREAD), pending.map { it.operation })
            assertEquals(listOf(1, 2), pending.map { it.clientSeq })
        }

    @Test
    fun `IN-13 an older reverse intent is dropped and a monotone one stays`() =
        runBlocking<Unit> {
            val queue = IntentQueue(MemoryIntentQueueStorage())
            queue.enqueue("inb_a", RelayInboxOperation.UNREAD, 2)
            queue.enqueue("inb_b", RelayInboxOperation.READ, 2)
            queue.observe("inb_a", 3)
            queue.observe("inb_b", 3)
            assertEquals(listOf("inb_b"), queue.pending().map { it.itemId })
        }

    @Test
    fun `IN-13 the queue survives a restart`() =
        runBlocking<Unit> {
            val storage = SharedPreferencesIntentQueueStorage(context)
            IntentQueue(storage).enqueue("inb_a", RelayInboxOperation.ARCHIVE, 1)
            val second = IntentQueue(storage)
            assertEquals(1, second.pending().size)
            assertEquals(1, second.enqueue("inb_b", RelayInboxOperation.READ, 1).clientSeq)
        }

    @Test
    fun `IN-12 a conflict is accepted silently unless the user just reversed`() =
        runBlocking<Unit> {
            val harness = Harness()
            val client = harness.client()
            harness.server.enqueue(
                "GET /v1/subscriber/inbox/items",
                Reply.json(200, Fixtures.list(Fixtures.item(version = 2, read = true), "c1", Fixtures.counters(0, 0, 4))),
            )
            client.store.coldSync()
            val item = client.store.items.value.single()
            harness.server.enqueue(
                "POST /v1/subscriber/inbox/items/${Fixtures.ITEM_ID}/intents",
                Reply.problem(409, "inbox_item_conflict", retryable = false, extra = ",\"current\":${Fixtures.state(version = 5, read = true)}"),
            )
            client.store.perform(RelayInboxOperation.UNREAD, item)
            assertEquals(RelayInboxNotice.UpdatedOnAnotherDevice(Fixtures.ITEM_ID), client.store.notice.value)
            assertTrue(client.store.items.value.single().read)
            assertEquals(5, client.store.items.value.single().stateVersion)
            val intent = harness.server.requests("POST /v1/subscriber/inbox/items/${Fixtures.ITEM_ID}/intents").single().json
            assertEquals("unread", intent.get("op").asString)
            assertEquals(2, intent.get("base_state_version").asInt)
            assertTrue(intent.has("client_seq"))
            assertTrue(client.store.queue.isEmpty())
        }

    @Test
    fun `IN-13 an offline intent waits and keeps its idempotency key`() =
        runBlocking<Unit> {
            val harness = Harness()
            val client = harness.client()
            harness.server.enqueue(
                "GET /v1/subscriber/inbox/items",
                Reply.json(200, Fixtures.list(Fixtures.item(version = 2), "c1", Fixtures.counters(1, 1, 4))),
            )
            client.store.coldSync()
            client.store.perform(RelayInboxOperation.READ, client.store.items.value.single())
            assertTrue(client.store.items.value.single().read)
            assertEquals(0, client.store.counters.value.unread)
            assertEquals(listOf(RelayInboxOperation.READ), client.store.queue.pending().map { it.operation })
            harness.server.enqueue(
                "POST /v1/subscriber/inbox/items/${Fixtures.ITEM_ID}/intents",
                Reply.json(
                    200,
                    """{"object":"inbox_intent_result","item_id":"${Fixtures.ITEM_ID}","op":"read","client_seq":0,""" +
                        """"result":"applied","state":${Fixtures.state(version = 3, read = true)},"counters":${Fixtures.counters(0, 0, 5)}}""",
                ),
            )
            client.store.drainQueue()
            assertTrue(client.store.queue.isEmpty())
            assertEquals(5, client.store.counters.value.version)
            val keys = harness.server.requests("POST /v1/subscriber/inbox/items/${Fixtures.ITEM_ID}/intents").map { it.header("Idempotency-Key") }
            assertEquals(1, keys.toSet().size)
        }

    @Test
    fun `IN-18 older counters are ignored`() {
        val client = Harness().client()
        client.store.apply(RelayInboxCounters(3, 3, 3, 10))
        client.store.apply(RelayInboxCounters(9, 9, 9, 9))
        assertEquals(3, client.store.counters.value.unseen)
    }

    @Test
    fun `IN-28 a realtime update applies only a newer state and IN-38 removes the notification`() =
        runBlocking<Unit> {
            val harness = Harness()
            val client = harness.client()
            harness.server.enqueue("GET /v1/subscriber/inbox/items/${Fixtures.ITEM_ID}", Reply.json(200, Fixtures.item()))
            client.messaging.handle(mapOf("relay_id" to Fixtures.ITEM_ID))
            harness.server.enqueue("GET /v1/subscriber/inbox/items", Reply.json(200, Fixtures.list(Fixtures.item(version = 2), "c1")))
            client.store.coldSync()
            val stale =
                RelayRealtimeEnvelope.parse(
                    """{"t":"inbox.item_updated","v":1,"ts":"2026-11-01T09:30:00Z","id":"c2",""" +
                        """"d":{"item_id":"${Fixtures.ITEM_ID}","state_version":2,"changes":{"read":true}},""" +
                        """"counters":{"unseen":0,"unread":0,"total":1,"version":6}}""",
                )!!
            client.store.handle(stale)
            assertFalse(client.store.items.value.single().read)
            val fresh =
                RelayRealtimeEnvelope.parse(
                    """{"t":"inbox.item_updated","v":1,"ts":"2026-11-01T09:30:00Z","id":"c3",""" +
                        """"d":{"item_id":"${Fixtures.ITEM_ID}","state_version":3,"changes":{"read":true,"seen":true}},""" +
                        """"counters":{"unseen":0,"unread":0,"total":1,"version":7}}""",
                )!!
            client.store.handle(fresh)
            assertTrue(client.store.items.value.single().read)
            assertEquals("c3", client.store.streamCursor)
            assertEquals(7, client.store.counters.value.version)
            val manager = context.getSystemService(NotificationManager::class.java)
            assertEquals(0, shadowOf(manager).allNotifications.size)
        }

    @Test
    fun `IN-29 a delta sync falls back to a cold sync when truncated`() =
        runBlocking<Unit> {
            val harness = Harness()
            val client = harness.client()
            harness.server.enqueue(
                "GET /v1/subscriber/inbox/items",
                Reply.json(200, Fixtures.list("", "c1")),
                Reply.json(200, Fixtures.list(Fixtures.item(), "c9")),
            )
            harness.server.enqueue(
                "GET /v1/subscriber/inbox/changes",
                Reply.json(
                    200,
                    """{"object":"inbox_changes","changes":[],"cursor":"c5","has_more":false,"truncated":true,""" +
                        """"resync_required":false,"counters":${Fixtures.counters(1, 1, 8)}}""",
                ),
            )
            client.store.synchronize()
            client.store.synchronize()
            assertEquals("since=c1", harness.server.requests("GET /v1/subscriber/inbox/changes").single().query)
            assertEquals(listOf(Fixtures.ITEM_ID), client.store.items.value.map { it.id })
            assertEquals("c9", client.store.streamCursor)
        }

    @Test
    fun `IN-35 foreground order and background close`() =
        runBlocking<Unit> {
            val calls = mutableListOf<String>()
            val steps =
                object : RelayLifecycleSteps {
                    override suspend fun refreshCounters() {
                        calls += "counters"
                    }

                    override suspend fun connectRealtime() {
                        calls += "connect"
                    }

                    override suspend fun synchronize() {
                        calls += "sync"
                    }

                    override suspend fun drainQueue() {
                        calls += "drain"
                    }

                    override suspend fun disconnectRealtime() {
                        calls += "disconnect"
                    }
                }
            val lifecycle = RelayLifecycle(steps)
            lifecycle.enterForeground()
            lifecycle.enterForeground()
            lifecycle.enterBackground()
            assertEquals(listOf("counters", "connect", "sync", "drain", "disconnect"), calls)
        }

    @Test
    fun `IN-35 a sync signal runs a delta sync and shows nothing`() =
        runBlocking<Unit> {
            val harness = Harness()
            val client = harness.client()
            harness.server.enqueue("GET /v1/subscriber/inbox/counters", Reply.json(200, Fixtures.counters(2, 2, 3)))
            harness.server.enqueue("GET /v1/subscriber/inbox/items", Reply.json(200, Fixtures.list("", "c1")))
            assertNull(client.messaging.handle(mapOf("sync" to "true", "counter_version" to "3")))
            assertEquals(2, client.store.counters.value.unseen)
        }
}
