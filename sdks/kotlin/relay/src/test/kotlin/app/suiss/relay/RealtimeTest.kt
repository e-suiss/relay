package app.suiss.relay

import com.google.gson.JsonObject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RealtimeTest {
    @Test
    fun `IN-23 the SSE parser joins data lines and skips comments`() {
        val parser = ServerSentEventParser()
        val lines = listOf(": keep-alive", "event: inbox.counters_changed", "id: c7", "data: {\"a\":", "data: 1}", "", "")
        val events = lines.mapNotNull { parser.feed(it) }
        assertEquals(listOf(ServerSentEvent("inbox.counters_changed", "{\"a\":\n1}", "c7")), events)
    }

    @Test
    fun `IN-23 Phoenix frames and the token subprotocol`() {
        val frame = PhoenixFrame("1", "1", "inbox", "phx_join", JsonObject().apply { addProperty("cursor", "c1") })
        val decoded = PhoenixFrame.decode(frame.encoded())!!
        assertEquals("inbox", decoded.topic)
        assertEquals("phx_join", decoded.event)
        assertEquals("c1", decoded.payload.get("cursor").asString)
        assertTrue(PhoenixFrame(null, "2", "phoenix", "heartbeat", JsonObject()).encoded().startsWith("[null,"))
        assertEquals("phoenix, base64url.bearer.phx.YT9iPg", PhoenixFrame.subprotocols("a?b>"))
    }

    @Test
    fun `IN-33 IN-52 close reasons and statuses`() {
        assertEquals(RelayRealtimeStop.RetryAfter(4), RelayRealtimeConnection.stopForCloseReason("retry-after=4", true))
        assertEquals(RelayRealtimeStop.AuthExpired, RelayRealtimeConnection.stopForCloseReason("auth_expired_token", true))
        assertEquals(
            RelayRealtimeStop.Refused("auth_subscriber_suspended"),
            RelayRealtimeConnection.stopForCloseReason("auth_subscriber_suspended", true),
        )
        assertEquals(RelayRealtimeStop.Unavailable, RelayRealtimeConnection.stopForCloseReason(null, false))
        assertEquals(RelayRealtimeStop.Closed, RelayRealtimeConnection.stopForCloseReason(null, true))
        assertEquals(RelayRealtimeStop.RetryAfter(3), RelayRealtimeConnection.stopForStatus(503, 3))
        assertEquals(RelayRealtimeStop.AuthExpired, RelayRealtimeConnection.stopForStatus(401, null))
    }

    @Test
    fun `IN-26 envelope decoding`() {
        val created =
            RelayRealtimeEnvelope.parse(
                """{"t":"inbox.item_created","v":1,"ts":"2026-11-01T09:30:00Z","id":"c1",""" +
                    """"d":{"item":${Fixtures.item()},"state_version":1},"counters":{"unseen":1,"unread":1,"total":1,"version":2}}""",
            )!!
        assertEquals(2, created.counters.version)
        val (json, thin) = created.createdItem!!
        assertFalse(thin)
        assertEquals("Order shipped", RelayInboxStore.decodeItem(json)?.title)
        assertNull(created.itemPatch)
    }

    @Test
    fun `IN-34 falls back from WebSocket to SSE and backs off with jitter`() =
        runBlocking<Unit> {
            val harness = Harness()
            val log = mutableListOf<String>()
            val connection =
                RelayRealtimeConnection(
                    transports =
                        listOf(
                            Scripted(RelayRealtimeTransportKind.WEB_SOCKET, log, listOf(RelayRealtimeStop.Unavailable)),
                            Scripted(
                                RelayRealtimeTransportKind.SERVER_SENT_EVENTS,
                                log,
                                listOf(RelayRealtimeStop.RetryAfter(3), RelayRealtimeStop.Closed),
                            ),
                            Scripted(RelayRealtimeTransportKind.LONG_POLL, log, emptyList()),
                        ),
                    tokens = TokenStore(harness.tokens, harness.clock),
                    clock = harness.clock,
                    random = FixedRandom(0.5),
                    scope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
                )
            connection.connect("c1")
            withTimeout(10_000) { while (synchronized(log) { log.size } < 4) delay(10) }
            connection.disconnect()
            assertEquals(listOf("WEB_SOCKET:c1", "SERVER_SENT_EVENTS:c1", "SERVER_SENT_EVENTS:c1"), synchronized(log) { log.take(3) })
            assertTrue(harness.clock.sleeps.first() >= 3_000)
            assertEquals(1_000L, harness.clock.sleeps[1])
        }

    @Test
    fun `IN-33 a refused connection stops`() =
        runBlocking<Unit> {
            val harness = Harness()
            val log = mutableListOf<String>()
            val connection =
                RelayRealtimeConnection(
                    transports = listOf(Scripted(RelayRealtimeTransportKind.WEB_SOCKET, log, listOf(RelayRealtimeStop.Refused("auth_tenant_suspended")))),
                    tokens = TokenStore(harness.tokens, harness.clock),
                    clock = harness.clock,
                    random = FixedRandom(),
                    scope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
                )
            connection.connect(null)
            withTimeout(10_000) { while (connection.state.value !is RelayRealtimeState.Stopped) delay(10) }
            assertEquals(RelayRealtimeState.Stopped("auth_tenant_suspended"), connection.state.value)
            assertEquals(listOf("WEB_SOCKET:-"), log)
        }
}

class Scripted(
    override val kind: RelayRealtimeTransportKind,
    private val log: MutableList<String>,
    private val script: List<RelayRealtimeStop>,
) : RelayRealtimeTransport {
    override suspend fun run(
        cursor: String?,
        token: String,
        onOpen: suspend () -> Unit,
        onEnvelope: suspend (RelayRealtimeEnvelope) -> Unit,
    ) {
        val calls =
            synchronized(log) {
                val count = log.count { it.startsWith("${kind.name}:") }
                log += "${kind.name}:${cursor ?: "-"}"
                count
            }
        if (calls < script.size) throw script[calls]
        onOpen()
        while (true) delay(10)
    }
}
