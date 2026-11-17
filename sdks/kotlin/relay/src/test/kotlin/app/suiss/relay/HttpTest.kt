package app.suiss.relay

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class HttpTest {
    @Test
    fun `X-29 a retry keeps the idempotency key and honours Retry-After`() =
        runBlocking<Unit> {
            val harness = Harness()
            harness.server.enqueue(
                "POST /v1/subscriber/inbox/read_all",
                Reply.problem(503, "service_unavailable", retryable = true, headers = mapOf("Retry-After" to "7")),
                Reply.json(
                    200,
                    """{"object":"inbox_read_all_result","scope":"all","category":null,"updated":2,""" +
                        """"cut_off":"2026-11-01T09:30:00Z","counters":${Fixtures.counters(0, 0, 9)}}""",
                ),
            )
            val counters = RelayInboxApi(harness.http).markAllRead()
            assertEquals(9, counters.version)
            val requests = harness.server.requests("POST /v1/subscriber/inbox/read_all")
            assertEquals(2, requests.size)
            assertNotNull(requests[0].header("Idempotency-Key"))
            assertEquals(requests[0].header("Idempotency-Key"), requests[1].header("Idempotency-Key"))
            assertEquals("2026-11-01", requests[0].header("Relay-Version"))
            assertEquals("Bearer subscriber-token-1", requests[0].header("Authorization"))
            assertTrue(harness.clock.sleeps.first() >= 7_000)
        }

    @Test
    fun `X-29 a non-retryable problem is thrown without a retry`() =
        runBlocking<Unit> {
            val harness = Harness()
            harness.server.enqueue("POST /v1/subscriber/inbox/read_all", Reply.problem(422, "validation_failed", retryable = false))
            try {
                RelayInboxApi(harness.http).markAllRead()
                fail("expected a problem")
            } catch (error: RelayException) {
                assertEquals("validation_failed", error.code)
                assertFalse(error.isRetryable)
            }
            assertEquals(1, harness.server.requests("POST /v1/subscriber/inbox/read_all").size)
            assertTrue(harness.clock.sleeps.isEmpty())
        }

    @Test
    fun `X-29 an expired token is refreshed once`() =
        runBlocking<Unit> {
            val harness = Harness()
            harness.server.enqueue(
                "GET /v1/subscriber/inbox/counters",
                Reply.problem(401, "auth_expired_token", retryable = false),
                Reply.json(200, Fixtures.counters(1, 2, 3)),
            )
            val counters = RelayInboxApi(harness.http).counters()
            assertEquals(2, counters.unread)
            assertEquals(listOf(false, true), harness.tokens.calls)
            val last = harness.server.requests("GET /v1/subscriber/inbox/counters").last()
            assertEquals("Bearer subscriber-token-2", last.header("Authorization"))
        }

    @Test
    fun `X-29 status defaults match the error catalog`() {
        val text = Fixtures.repositoryRoot.resolve("contracts/errors.yaml").readText()
        val defaults = ErrorCatalog.retryableDefaults(text)
        assertTrue(defaults.isNotEmpty())
        defaults.forEach { entry ->
            assertEquals("status ${entry.status} ${entry.code}", entry.retryable, RetryClassifier.defaultRetryable(entry.status, entry.code))
        }
        ErrorCatalog.codes(text).forEach { entry ->
            assertEquals(entry.code, entry.retryable, RetryClassifier.isRetryable(entry.status, entry.code, entry.retryable))
        }
    }

    @Test
    fun `X-31 a missing scope sends nothing`() =
        runBlocking<Unit> {
            val harness = Harness(scopes = setOf(RelayScope.INBOX_READ))
            try {
                RelayInboxApi(harness.http).markAllRead()
                fail("expected a missing scope")
            } catch (error: RelayException.MissingScope) {
                assertEquals(RelayScope.INBOX_WRITE, error.scope)
            }
            assertTrue(harness.server.recorded.isEmpty())
        }

    @Test
    fun `X-31 the token is never printed`() {
        val token = RelaySubscriberToken("secret-value", 0)
        assertFalse(token.toString().contains("secret-value"))
    }

    @Test
    fun `IN-34 backoff is full jitter between one and sixty seconds`() {
        val backoff = FullJitterBackoff(1_000, 60_000)
        assertEquals(1_000, backoff.ceiling(0))
        assertEquals(8_000, backoff.ceiling(3))
        assertEquals(60_000, backoff.ceiling(10))
        assertEquals(2_000, backoff.delay(3, FixedRandom(0.25)))
        assertEquals(0, backoff.delay(0, FixedRandom(0.0)))
        assertEquals(4_000, backoff.delay(0, FixedRandom(0.5), 4_000))
    }
}

object ErrorCatalog {
    data class Entry(
        val status: Int,
        val code: String?,
        val retryable: Boolean,
    )

    fun retryableDefaults(text: String): List<Entry> {
        val block = text.substringAfter("retryable_defaults:\n").substringBefore("\ncodes:\n")
        val result = mutableListOf<Entry>()
        var status: Int? = null
        var code: String? = null
        block.lines().forEach { line ->
            when {
                line.startsWith("  - status:") -> {
                    status = line.removePrefix("  - status:").trim().toIntOrNull()
                    code = null
                }
                line.startsWith("    code: ") -> code = line.removePrefix("    code: ")
                line.startsWith("    retryable: ") -> status?.let { result += Entry(it, code, line.endsWith("true")) }
            }
        }
        return result
    }

    fun codes(text: String): List<Entry> {
        val block = text.substringAfter("\ncodes:\n")
        val result = mutableListOf<Entry>()
        var code: String? = null
        var status: Int? = null
        block.lines().forEach { line ->
            when {
                line.startsWith("  - code: ") -> {
                    code = line.removePrefix("  - code: ")
                    status = null
                }
                line.startsWith("    status: ") -> status = line.removePrefix("    status: ").toIntOrNull()
                line.startsWith("    retryable: ") -> {
                    val currentCode = code
                    val currentStatus = status
                    if (currentCode != null && currentStatus != null) {
                        result += Entry(currentStatus, currentCode, line.endsWith("true"))
                        code = null
                    }
                }
            }
        }
        return result
    }
}
