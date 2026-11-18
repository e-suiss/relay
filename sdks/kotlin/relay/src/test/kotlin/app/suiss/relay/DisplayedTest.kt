package app.suiss.relay

import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

class RecordingScheduler : DisplayedScheduler {
    val immediate = mutableListOf<suspend () -> Unit>()
    val intervals = mutableListOf<Long>()

    override fun now(block: suspend () -> Unit) {
        immediate += block
    }

    override fun every(
        intervalMillis: Long,
        block: suspend () -> Unit,
    ) {
        intervals += intervalMillis
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class DisplayedTest {
    private val route = "POST /v1/subscriber/displayed_notifications"
    private val accepted = """{"object":"displayed_notifications","accepted":1,"duplicates":0}"""

    private fun reporter(
        harness: Harness,
        enabled: Boolean = true,
        scheduler: RecordingScheduler = RecordingScheduler(),
    ): RelayDisplayedNotifications = RelayDisplayedNotifications.over(RelayHttp(configuration(harness, enabled), harness.okHttp), scheduler)

    @Test
    fun `OP-54 reporting is off by default and sends nothing`() =
        runBlocking<Unit> {
            val harness = Harness()
            assertFalse(harness.configuration.reportDisplayedNotifications)
            val scheduler = RecordingScheduler()
            val displayed = reporter(harness, enabled = false, scheduler = scheduler)
            displayed.report(Fixtures.ITEM_ID)
            displayed.flush()
            assertTrue(displayed.pending.isEmpty())
            assertTrue(scheduler.intervals.isEmpty())
            assertTrue(harness.server.requests(route).isEmpty())
        }

    @Test
    fun `OP-95 only the SHA-256 digest and the display time leave the device`() =
        runBlocking<Unit> {
            val harness = Harness()
            val scheduler = RecordingScheduler()
            val displayed = reporter(harness, scheduler = scheduler)
            assertEquals(listOf(30_000L), scheduler.intervals)
            harness.server.enqueue(route, Reply.json(202, accepted))
            displayed.report("ntf_01j9zq3k4m5n6p7q8r9s0t1v2w")
            displayed.flush()
            val request = harness.server.requests(route).single()
            val item = request.json.getAsJsonArray("notifications").single().asJsonObject
            assertEquals(setOf("digest", "displayed_at"), item.keySet())
            assertEquals(RelayDisplayedNotifications.digest("ntf_01j9zq3k4m5n6p7q8r9s0t1v2w"), item.get("digest").asString)
            assertTrue(Regex("^[0-9a-f]{64}$").matches(item.get("digest").asString))
            assertEquals("2027-01-15T08:00:00Z", item.get("displayed_at").asString)
            assertFalse(request.body.contains("ntf_"))
            assertTrue(request.header("Idempotency-Key")!!.startsWith("rly-"))
            assertEquals("Bearer subscriber-token-1", request.header("Authorization"))
            assertTrue(displayed.pending.isEmpty())
        }

    @Test
    fun `OP-95 the digest is lowercase hex SHA-256 of the UTF-8 identifier`() {
        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            RelayDisplayedNotifications.digest("abc"),
        )
    }

    @Test
    fun `OP-95 the same identifier displayed twice is reported twice`() =
        runBlocking<Unit> {
            val harness = Harness()
            val displayed = reporter(harness)
            harness.server.enqueue(route, Reply.json(202, accepted))
            displayed.report(Fixtures.ITEM_ID)
            displayed.report(Fixtures.ITEM_ID)
            displayed.flush()
            val sent = harness.server.requests(route).single().json.getAsJsonArray("notifications")
            assertEquals(2, sent.size())
            assertEquals(sent[0].asJsonObject.get("digest"), sent[1].asJsonObject.get("digest"))
        }

    @Test
    fun `OP-95 twenty waiting reports start a flush and a batch holds at most 100`() =
        runBlocking<Unit> {
            val harness = Harness()
            val scheduler = RecordingScheduler()
            val displayed = reporter(harness, scheduler = scheduler)
            repeat(19) { displayed.report("ntf_$it") }
            assertTrue(scheduler.immediate.isEmpty())
            displayed.report("ntf_19")
            assertEquals(1, scheduler.immediate.size)
            repeat(130) { displayed.report("ntf_more_$it") }
            harness.server.enqueue(route, Reply.json(202, accepted), Reply.json(202, accepted))
            scheduler.immediate.first().invoke()
            val sizes = harness.server.requests(route).map { it.json.getAsJsonArray("notifications").size() }
            assertEquals(listOf(100, 50), sizes)
            assertTrue(displayed.pending.isEmpty())
        }

    @Test
    fun `OP-95 a failed batch is retried with the same idempotency key`() =
        runBlocking<Unit> {
            val harness = Harness()
            val displayed = reporter(harness)
            displayed.report(Fixtures.ITEM_ID)
            displayed.flush()
            assertEquals(1, displayed.pending.size)
            displayed.report(Fixtures.DELIVERY_ID)
            harness.server.enqueue(route, Reply.json(202, accepted), Reply.json(202, accepted))
            displayed.flush()
            val keys = harness.server.requests(route).map { it.header("Idempotency-Key") }
            assertEquals(3, keys.size)
            assertEquals(keys[0], keys[1])
            assertNotEquals(keys[1], keys[2])
            assertEquals(1, harness.server.requests(route)[1].json.getAsJsonArray("notifications").size())
            assertTrue(displayed.pending.isEmpty())
        }

    @Test
    fun `OP-95 batches older than 24 hours are dropped`() =
        runBlocking<Unit> {
            val harness = Harness()
            val displayed = reporter(harness)
            displayed.report(Fixtures.ITEM_ID)
            displayed.flush()
            assertEquals(1, displayed.pending.size)
            harness.clock.sleep(24 * 60 * 60 * 1_000L + 1)
            displayed.flush()
            assertTrue(displayed.pending.isEmpty())
            assertEquals(1, harness.server.requests(route).size)
        }

    @Test
    fun `OP-95 the background flushes after the realtime connection closes`() =
        runBlocking<Unit> {
            val calls = mutableListOf<String>()
            val steps =
                object : RelayLifecycleSteps {
                    override suspend fun refreshCounters() = Unit

                    override suspend fun connectRealtime() = Unit

                    override suspend fun synchronize() = Unit

                    override suspend fun drainQueue() = Unit

                    override suspend fun disconnectRealtime() {
                        calls += "disconnect"
                    }

                    override suspend fun flushDisplayedNotifications() {
                        calls += "flush"
                    }
                }
            val lifecycle = RelayLifecycle(steps)
            lifecycle.enterForeground()
            lifecycle.enterBackground()
            assertEquals(listOf("disconnect", "flush"), calls)
        }

    @Test
    fun `OP-95 the inbox reports an item once and a shown push by its notification id`() =
        runBlocking<Unit> {
            val harness = Harness()
            val client = client(harness)
            val item = RelayInboxItem(id = Fixtures.ITEM_ID, stateVersion = 1)
            client.store.markDisplayed(item)
            client.store.markDisplayed(item)
            assertEquals(listOf(RelayDisplayedNotifications.digest(Fixtures.ITEM_ID)), client.displayed.pending.map { it.digest })
            harness.server.enqueue(
                "POST /v1/subscriber/push_receipts",
                Reply.json(202, """{"object":"push_receipt","delivery_id":"${Fixtures.DELIVERY_ID}","receipt":"displayed"}"""),
            )
            harness.server.enqueue(
                "GET /v1/subscriber/push_content/${Fixtures.DELIVERY_ID}",
                Reply.json(
                    200,
                    """{"object":"push_content","delivery_id":"${Fixtures.DELIVERY_ID}",""" +
                        """"notification_id":"ntf_01j9zq3k4m5n6p7q8r9s0t1v2w","channel":"push","locale":"en",""" +
                        """"content":{"title":"Order shipped","body":"On its way"}}""",
                ),
            )
            client.messaging.handle(mapOf("relay_id" to Fixtures.DELIVERY_ID))
            assertEquals(
                RelayDisplayedNotifications.digest("ntf_01j9zq3k4m5n6p7q8r9s0t1v2w"),
                client.displayed.pending.last().digest,
            )
            harness.server.enqueue(route, Reply.json(202, accepted))
            client.flushDisplayedNotifications()
            assertEquals(2, harness.server.requests(route).single().json.getAsJsonArray("notifications").size())
            val disabled = Harness().client()
            disabled.store.markDisplayed(item)
            assertTrue(disabled.displayed.pending.isEmpty())
        }

    private fun configuration(
        harness: Harness,
        enabled: Boolean,
    ): RelayConfiguration =
        RelayConfiguration(
            baseUrl = harness.configuration.baseUrl,
            appIdentifier = harness.configuration.appIdentifier,
            tokenProvider = harness.tokens,
            clock = harness.clock,
            random = harness.configuration.random,
            logger = harness.logger,
            maxRetries = 0,
            reportDisplayedNotifications = enabled,
        )

    private fun client(harness: Harness): RelayClient =
        RelayClient(
            configuration = configuration(harness, enabled = true),
            context = ApplicationProvider.getApplicationContext(),
            okHttp = harness.okHttp,
            deviceStorage = MemoryDeviceStorage(),
            queueStorage = MemoryIntentQueueStorage(),
            settings = { RelayNotificationSettings(RelayPermission.GRANTED) },
            realtimeTransports = emptyList(),
            scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
            smallIcon = android.R.drawable.ic_dialog_info,
            launchIntent = { null },
        )
}
