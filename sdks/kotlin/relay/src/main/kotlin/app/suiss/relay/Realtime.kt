package app.suiss.relay

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.io.IOException
import kotlin.coroutines.coroutineContext

/** The realtime transports, in the order the SDK tries them (IN-23). */
public enum class RelayRealtimeTransportKind { WEB_SOCKET, SERVER_SENT_EVENTS, LONG_POLL }

/** Why a transport stopped. */
public sealed class RelayRealtimeStop : Exception() {
    /** The transport cannot be used here; the next one is tried. */
    public object Unavailable : RelayRealtimeStop()

    /** The server asked to come back later. */
    public data class RetryAfter(
        val seconds: Long,
    ) : RelayRealtimeStop()

    /** The token expired; a fresh one is fetched. */
    public object AuthExpired : RelayRealtimeStop()

    /** The server refused for good (suspension, origin); the connection stops. */
    public data class Refused(
        val reason: String,
    ) : RelayRealtimeStop()

    /** The connection ended; it is opened again after a backoff. */
    public object Closed : RelayRealtimeStop()
}

/** The state of the realtime connection. */
public sealed class RelayRealtimeState {
    public object Disconnected : RelayRealtimeState()

    public data class Connecting(
        val kind: RelayRealtimeTransportKind,
    ) : RelayRealtimeState()

    public data class Connected(
        val kind: RelayRealtimeTransportKind,
    ) : RelayRealtimeState()

    public data class Waiting(
        val millis: Long,
    ) : RelayRealtimeState()

    public data class Stopped(
        val reason: String,
    ) : RelayRealtimeState()
}

/** One realtime transport; [run] returns or throws when the connection ends. */
public interface RelayRealtimeTransport {
    public val kind: RelayRealtimeTransportKind

    public suspend fun run(
        cursor: String?,
        token: String,
        onOpen: suspend () -> Unit,
        onEnvelope: suspend (RelayRealtimeEnvelope) -> Unit,
    )
}

// IN-34
// IN-35

/**
 * Keeps one realtime connection while the app is in the foreground: WebSocket first, then SSE, then
 * long-poll; every reconnect waits with full jitter (1 to 60 seconds) and honours `Retry-After`.
 */
public class RelayRealtimeConnection internal constructor(
    private val transports: List<RelayRealtimeTransport>,
    private val tokens: TokenStore,
    private val clock: RelayClock,
    private val random: RelayRandom,
    private val scope: CoroutineScope,
) {
    private val backoff = FullJitterBackoff(baseMillis = 1_000, capMillis = 60_000)
    private var job: Job? = null
    private val mutableState = MutableStateFlow<RelayRealtimeState>(RelayRealtimeState.Disconnected)

    /** The connection state. */
    public val state: StateFlow<RelayRealtimeState> = mutableState

    /** Receives every envelope in order. */
    public var onEnvelope: suspend (RelayRealtimeEnvelope) -> Unit = {}

    /** The id of the last envelope received. */
    public var cursor: String? = null
        private set

    /** Opens the stream after [from], or at the head with the current counters when it is `null`. */
    @Synchronized
    public fun connect(from: String?) {
        if (from != null) cursor = from
        if (job?.isActive == true) return
        job = scope.launch { loop() }
    }

    /** Closes the connection (the app went to the background, IN-35). */
    @Synchronized
    public fun disconnect() {
        job?.cancel()
        job = null
        mutableState.value = RelayRealtimeState.Disconnected
    }

    private suspend fun loop() {
        var index = 0
        var attempt = 0
        while (coroutineContext.isActive && transports.isNotEmpty()) {
            val transport = transports[index]
            mutableState.value = RelayRealtimeState.Connecting(transport.kind)
            var wait: Long? = null
            try {
                val token = tokens.token()
                transport.run(
                    cursor = cursor,
                    token = token.value,
                    onOpen = { mutableState.value = RelayRealtimeState.Connected(transport.kind) },
                    onEnvelope = { envelope ->
                        envelope.id?.let { cursor = it }
                        onEnvelope(envelope)
                    },
                )
                attempt = 0
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (stop: RelayRealtimeStop) {
                when (stop) {
                    RelayRealtimeStop.Unavailable -> {
                        if (index + 1 < transports.size) {
                            index += 1
                            continue
                        }
                    }

                    is RelayRealtimeStop.RetryAfter -> {
                        wait = stop.seconds * 1_000
                    }

                    RelayRealtimeStop.AuthExpired -> {
                        runCatching { tokens.refresh() }
                        continue
                    }

                    is RelayRealtimeStop.Refused -> {
                        mutableState.value = RelayRealtimeState.Stopped(stop.reason)
                        return
                    }

                    RelayRealtimeStop.Closed -> {
                        Unit
                    }
                }
            } catch (error: Exception) {
                if (error is CancellationException) throw error
            }
            val pause = backoff.delay(attempt, random, wait)
            attempt += 1
            mutableState.value = RelayRealtimeState.Waiting(pause)
            clock.sleep(pause)
        }
    }

    internal companion object {
        // IN-33
        // IN-52
        fun stopForCloseReason(
            reason: String?,
            joined: Boolean,
        ): RelayRealtimeStop =
            when {
                reason.isNullOrEmpty() -> {
                    if (joined) RelayRealtimeStop.Closed else RelayRealtimeStop.Unavailable
                }

                reason.startsWith("retry-after=") -> {
                    RelayRealtimeStop.RetryAfter(reason.removePrefix("retry-after=").toLongOrNull() ?: 1)
                }

                reason == "auth_expired_token" || reason == "auth_invalid_token" -> {
                    RelayRealtimeStop.AuthExpired
                }

                reason == "connection_limit" -> {
                    RelayRealtimeStop.Closed
                }

                else -> {
                    RelayRealtimeStop.Refused(reason)
                }
            }

        fun stopForStatus(
            status: Int,
            retryAfter: Long?,
        ): RelayRealtimeStop =
            when {
                status == 401 -> RelayRealtimeStop.AuthExpired
                status == 429 || status == 503 -> RelayRealtimeStop.RetryAfter(retryAfter ?: 1)
                status == 403 -> RelayRealtimeStop.Refused("forbidden")
                status == 404 -> RelayRealtimeStop.Unavailable
                status >= 500 -> RelayRealtimeStop.Closed
                else -> RelayRealtimeStop.Refused("status_$status")
            }
    }
}

/** The Phoenix Channels WebSocket at `/v1/realtime/websocket`. */
internal class WebSocketRealtimeTransport(
    private val http: RelayHttp,
    private val deviceId: () -> String?,
) : RelayRealtimeTransport {
    override val kind: RelayRealtimeTransportKind = RelayRealtimeTransportKind.WEB_SOCKET

    override suspend fun run(
        cursor: String?,
        token: String,
        onOpen: suspend () -> Unit,
        onEnvelope: suspend (RelayRealtimeEnvelope) -> Unit,
    ) {
        val events = Channel<SocketEvent>(Channel.UNLIMITED)
        val request =
            Request
                .Builder()
                .url(http.url("v1/realtime/websocket", mapOf("vsn" to "2.0.0", "device_id" to deviceId())))
                .header("Sec-WebSocket-Protocol", PhoenixFrame.subprotocols(token))
                .build()
        val socket =
            http.client.newWebSocket(
                request,
                object : WebSocketListener() {
                    override fun onOpen(
                        webSocket: WebSocket,
                        response: Response,
                    ) {
                        events.trySend(SocketEvent.Open)
                    }

                    override fun onMessage(
                        webSocket: WebSocket,
                        text: String,
                    ) {
                        events.trySend(SocketEvent.Text(text))
                    }

                    override fun onClosing(
                        webSocket: WebSocket,
                        code: Int,
                        reason: String,
                    ) {
                        events.trySend(SocketEvent.Closed(reason))
                        webSocket.close(1000, null)
                    }

                    override fun onFailure(
                        webSocket: WebSocket,
                        t: Throwable,
                        response: Response?,
                    ) {
                        events.trySend(SocketEvent.Failed(response?.code))
                    }
                },
            )
        var joined = false
        var opened = false
        val heartbeat =
            CoroutineScope(coroutineContext).launch {
                var ref = 1
                while (isActive) {
                    delay(30_000)
                    ref += 1
                    socket.send(PhoenixFrame(null, "h$ref", "phoenix", "heartbeat", JsonObject()).encoded())
                }
            }
        try {
            for (event in events) {
                when (event) {
                    SocketEvent.Open -> {
                        opened = true
                        val payload = JsonObject().apply { cursor?.let { addProperty("cursor", it) } }
                        socket.send(PhoenixFrame("1", "1", "inbox", "phx_join", payload).encoded())
                    }

                    is SocketEvent.Text -> {
                        val frame = PhoenixFrame.decode(event.text) ?: continue
                        if (frame.event == "phx_reply" && frame.ref == "1") {
                            if (frame.payload.string("status") != "ok") {
                                val response = frame.payload.get("response")?.takeIf { it.isJsonObject }?.asJsonObject
                                throw RelayRealtimeStop.Refused(response?.string("reason") ?: "join_refused")
                            }
                            joined = true
                            onOpen()
                            continue
                        }
                        if (frame.event == "phx_error" || frame.event == "phx_close") throw RelayRealtimeStop.Closed
                        if (frame.topic != "inbox") continue
                        RelayRealtimeEnvelope.from(frame.payload)?.let { onEnvelope(it) }
                    }

                    is SocketEvent.Closed -> {
                        throw RelayRealtimeConnection.stopForCloseReason(event.reason, joined)
                    }

                    is SocketEvent.Failed -> {
                        throw if (!opened) RelayRealtimeStop.Unavailable else RelayRealtimeStop.Closed
                    }
                }
            }
        } finally {
            heartbeat.cancel()
            socket.cancel()
        }
    }

    private sealed class SocketEvent {
        object Open : SocketEvent()

        class Text(
            val text: String,
        ) : SocketEvent()

        class Closed(
            val reason: String,
        ) : SocketEvent()

        class Failed(
            val status: Int?,
        ) : SocketEvent()
    }
}

/** The SSE stream at `/v1/realtime/events`. */
internal class ServerSentEventsRealtimeTransport(
    private val http: RelayHttp,
    private val deviceId: () -> String?,
) : RelayRealtimeTransport {
    override val kind: RelayRealtimeTransportKind = RelayRealtimeTransportKind.SERVER_SENT_EVENTS

    override suspend fun run(
        cursor: String?,
        token: String,
        onOpen: suspend () -> Unit,
        onEnvelope: suspend (RelayRealtimeEnvelope) -> Unit,
    ) {
        val request =
            Request
                .Builder()
                .url(http.url("v1/realtime/events", mapOf("device_id" to deviceId())))
                .header("Authorization", "Bearer $token")
                .header("Accept", "text/event-stream")
                .header("Relay-Version", RelayConfiguration.API_VERSION)
                .apply { if (cursor != null) header("Last-Event-ID", cursor) }
                .build()
        val streaming: OkHttpClient = http.client.newBuilder().readTimeout(java.time.Duration.ofSeconds(90)).build()
        val response =
            withContext(Dispatchers.IO) {
                try {
                    streaming.newCall(request).execute()
                } catch (error: IOException) {
                    throw RelayRealtimeStop.Unavailable
                }
            }
        response.use {
            if (it.code != 200) {
                throw RelayRealtimeConnection.stopForStatus(it.code, it.header("Retry-After")?.toLongOrNull())
            }
            onOpen()
            val parser = ServerSentEventParser()
            val source = it.body.source()
            while (coroutineContext.isActive) {
                val line =
                    withContext(Dispatchers.IO) {
                        try {
                            source.readUtf8Line()
                        } catch (error: IOException) {
                            null
                        }
                    } ?: throw RelayRealtimeStop.Closed
                val event = parser.feed(line) ?: continue
                RelayRealtimeEnvelope.parse(event.data)?.let { envelope -> onEnvelope(envelope) }
            }
        }
    }
}

/** The long-poll at `/v1/realtime/poll`, the last-resort transport. */
internal class LongPollRealtimeTransport(
    private val http: RelayHttp,
) : RelayRealtimeTransport {
    override val kind: RelayRealtimeTransportKind = RelayRealtimeTransportKind.LONG_POLL

    override suspend fun run(
        cursor: String?,
        token: String,
        onOpen: suspend () -> Unit,
        onEnvelope: suspend (RelayRealtimeEnvelope) -> Unit,
    ) {
        var next = cursor
        var opened = false
        while (coroutineContext.isActive) {
            val answer =
                try {
                    http.send(RelayScope.INBOX_READ, "GET", http.url("v1/realtime/poll", mapOf("cursor" to next)))
                } catch (error: RelayException.Problem) {
                    throw RelayRealtimeConnection.stopForStatus(error.problem.status, error.retryAfterSeconds)
                } catch (error: RelayException) {
                    throw RelayRealtimeStop.Closed
                }
            if (!opened) {
                opened = true
                onOpen()
            }
            val json = JsonParser.parseString(answer.body).asJsonObject
            json.getAsJsonArray("events")?.forEach { element ->
                if (element.isJsonObject) RelayRealtimeEnvelope.from(element.asJsonObject)?.let { onEnvelope(it) }
            }
            next = json.string("cursor") ?: next
        }
    }
}
