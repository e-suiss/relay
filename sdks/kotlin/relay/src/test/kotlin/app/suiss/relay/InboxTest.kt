package app.suiss.relay

import android.app.NotificationManager
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import app.suiss.relay.api.model.InboxItem
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
                Reply.problem(
                    409,
                    "inbox_item_conflict",
                    retryable = false,
                    extra = ",\"current\":${Fixtures.state(version = 5, read = true)}",
                ),
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
                        """"result":"applied","state":${Fixtures.state(
                            version = 3,
                            read = true,
                        )},"counters":${Fixtures.counters(0, 0, 5)}}""",
                ),
            )
            client.store.drainQueue()
            assertTrue(client.store.queue.isEmpty())
            assertEquals(5, client.store.counters.value.version)
            val keys =
                harness.server.requests("POST /v1/subscriber/inbox/items/${Fixtures.ITEM_ID}/intents").map {
                    it.header("Idempotency-Key")
                }
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

    @Test
    fun `AG-34 AG-35 an item carries its sender type, approval flag and waitpoint`() =
        runBlocking<Unit> {
            val harness = Harness()
            val client = harness.client()
            val agentItem =
                Fixtures.item(extra = ",\"sender_type\":\"agent\",\"approval\":false,\"waitpoint\":${Fixtures.waitpoint()}")
            harness.server.enqueue("GET /v1/subscriber/inbox/items", Reply.json(200, Fixtures.list(agentItem, "c1")))
            client.store.coldSync()
            val item = client.store.items.value.single()
            assertTrue(item.isFromAgent)
            assertFalse(item.isApproval)
            val waitpoint = item.waitpoint!!
            assertEquals(Fixtures.WAITPOINT_ID, waitpoint.id)
            assertEquals(RelayWaitpointKind.RESPONSE, waitpoint.kind)
            assertEquals(RelayWaitpointStatus.AWAITING, waitpoint.status)
            assertEquals(listOf(RelayWaitpointOption("Yes", "yes"), RelayWaitpointOption("No", "no")), waitpoint.options)
            assertTrue(waitpoint.acceptsResponse)
            val plain = RelayInboxItem.from(harness.http.gson.fromJson(Fixtures.item(), InboxItem::class.java))
            assertNull(plain.senderType)
            assertNull(plain.waitpoint)
            assertFalse(plain.isApproval)
        }

    @Test
    fun `AG-26 AG-28 a response carries the subject digest and the receipt resolves the waitpoint`() =
        runBlocking<Unit> {
            val harness = Harness()
            val client = harness.client()
            val item = Fixtures.item(extra = ",\"sender_type\":\"agent\",\"approval\":false,\"waitpoint\":${Fixtures.waitpoint()}")
            harness.server.enqueue("GET /v1/subscriber/inbox/items", Reply.json(200, Fixtures.list(item, "c1")))
            client.store.coldSync()
            harness.server.enqueue(
                "POST /v1/subscriber/waitpoints/${Fixtures.WAITPOINT_ID}/response",
                Reply.json(
                    200,
                    """{"object":"waitpoint_response_receipt","waitpoint_id":"${Fixtures.WAITPOINT_ID}","status":"responded",""" +
                        """"responder":{"kind":"subscriber","recipient_id":"${Fixtures.SUBSCRIBER_ID}"},""" +
                        """"evidence_level":"relay_session","responded_at":"2026-11-01T10:00:00Z"}""",
                ),
            )
            val shown = client.store.items.value.single()
            client.store.respond(shown, shown.waitpoint!!.options.first())
            val request = harness.server.requests("POST /v1/subscriber/waitpoints/${Fixtures.WAITPOINT_ID}/response").single()
            assertEquals("yes", request.json.get("response").asString)
            assertEquals("sha256:${Fixtures.DIGEST}", request.json.get("subject_digest").asString)
            assertNull(request.json.get("approval"))
            assertNull(request.header("Idempotency-Key"))
            val waitpoint = client.store.items.value.single().waitpoint!!
            assertEquals(RelayWaitpointStatus.RESPONDED, waitpoint.status)
            assertEquals(RelayWaitpointResponder(isAgent = false, recipientId = Fixtures.SUBSCRIBER_ID), waitpoint.responder)
            assertEquals("2026-11-01T10:00:00Z", waitpoint.respondedAt)
            assertFalse(waitpoint.acceptsResponse)
        }

    @Test
    fun `AG-28 a refused response puts the waitpoint back`() =
        runBlocking<Unit> {
            val harness = Harness()
            val client = harness.client()
            val item = Fixtures.item(extra = ",\"waitpoint\":${Fixtures.waitpoint()}")
            harness.server.enqueue("GET /v1/subscriber/inbox/items", Reply.json(200, Fixtures.list(item, "c1")))
            client.store.coldSync()
            harness.server.enqueue(
                "POST /v1/subscriber/waitpoints/${Fixtures.WAITPOINT_ID}/response",
                Reply.problem(409, "waitpoint_already_resolved", retryable = false),
            )
            val shown = client.store.items.value.single()
            client.store.respond(shown, shown.waitpoint!!.options.last())
            assertEquals(RelayWaitpointStatus.AWAITING, client.store.items.value.single().waitpoint!!.status)
            assertTrue(client.store.lastError.value is RelayException.Problem)
        }

    @Test
    fun `IN-6 AG-32 an approval item is never answered`() =
        runBlocking<Unit> {
            val harness = Harness()
            val client = harness.client()
            val approval =
                Fixtures.item(
                    extra =
                        ",\"sender_type\":\"system\",\"approval\":true,\"waitpoint\":" +
                            Fixtures.waitpoint(kind = "approval", approvalUrl = "https://access.test/approvals/1"),
                )
            harness.server.enqueue("GET /v1/subscriber/inbox/items", Reply.json(200, Fixtures.list(approval, "c1")))
            client.store.coldSync()
            val item = client.store.items.value.single()
            assertTrue(item.isApproval)
            assertFalse(item.isFromAgent)
            assertEquals("https://access.test/approvals/1", item.waitpoint!!.approvalUrl)
            assertFalse(item.waitpoint!!.acceptsResponse)
            client.store.respond(item, item.waitpoint!!.options.first())
            assertTrue(harness.server.requests("POST /v1/subscriber/waitpoints/${Fixtures.WAITPOINT_ID}/response").isEmpty())
            assertEquals(RelayWaitpointStatus.AWAITING, client.store.items.value.single().waitpoint!!.status)
        }

    @Test
    fun `AG-35 the delta sync carries the waitpoint fields`() =
        runBlocking<Unit> {
            val harness = Harness()
            val change =
                """{"type":"updated","cursor":"c2","item_id":"${Fixtures.ITEM_ID}","state_version":2,"item":""" +
                    Fixtures.item(
                        version = 2,
                        extra = ",\"sender_type\":\"agent\",\"waitpoint\":${Fixtures.waitpoint(status = "not_awaited")}",
                    ) + "}"
            harness.server.enqueue(
                "GET /v1/subscriber/inbox/changes",
                Reply.json(
                    200,
                    """{"object":"inbox_changes","changes":[$change],"cursor":"c2","has_more":false,"truncated":false,""" +
                        """"resync_required":false,"counters":${Fixtures.counters(0, 1, 3)}}""",
                ),
            )
            val delta = RelayInboxApi(harness.http).changes("c1")
            val upsert = delta.changes.single() as RelayInboxChange.Upsert
            assertTrue(upsert.item.isFromAgent)
            assertEquals(RelayWaitpointStatus.NOT_AWAITED, upsert.item.waitpoint?.status)
        }
}
