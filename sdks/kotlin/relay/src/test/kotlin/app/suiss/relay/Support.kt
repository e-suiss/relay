package app.suiss.relay

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import java.io.File
import java.io.IOException
import java.util.UUID

class Recorded(
    val request: Request,
    val body: String,
) {
    val json: JsonObject get() = JsonParser.parseString(body).asJsonObject

    fun header(name: String): String? = request.header(name)

    val path: String get() = request.url.encodedPath

    val query: String? get() = request.url.encodedQuery
}

class Reply(
    val status: Int,
    val body: String,
    val headers: Map<String, String> = emptyMap(),
) {
    companion object {
        fun json(
            status: Int,
            body: String,
            headers: Map<String, String> = emptyMap(),
        ) = Reply(status, body, headers)

        fun problem(
            status: Int,
            code: String,
            retryable: Boolean? = null,
            extra: String = "",
            headers: Map<String, String> = emptyMap(),
        ): Reply {
            val retry = retryable?.let { ",\"retryable\":$it" } ?: ""
            return Reply(
                status,
                "{\"type\":\"https://relay.test/v1/errors/$code\",\"title\":\"t\",\"status\":$status,\"code\":\"$code\"$retry$extra}",
                headers,
            )
        }
    }
}

class FakeServer : Interceptor {
    private val queues = mutableMapOf<String, ArrayDeque<Reply>>()
    val recorded = mutableListOf<Recorded>()

    @Synchronized
    fun enqueue(
        route: String,
        vararg replies: Reply,
    ) {
        queues.getOrPut(route) { ArrayDeque() }.addAll(replies)
    }

    @Synchronized
    fun requests(route: String): List<Recorded> = recorded.filter { route(it.request) == route }

    private fun route(request: Request): String = "${request.method} ${request.url.encodedPath}"

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val body = Buffer().also { request.body?.writeTo(it) }.readUtf8()
        val reply =
            synchronized(this) {
                recorded += Recorded(request, body)
                queues[route(request)]?.removeFirstOrNull()
            } ?: throw IOException("offline")
        val builder =
            Response
                .Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(reply.status)
                .message("status")
                .header("Request-Id", "req_test")
                .header("Relay-Version", "2026-11-01")
                .body(reply.body.toResponseBody("application/json".toMediaType()))
        reply.headers.forEach { (name, value) -> builder.header(name, value) }
        return builder.build()
    }
}

class FakeClock : RelayClock {
    private var now = 1_800_000_000_000L
    val sleeps = mutableListOf<Long>()

    @Synchronized
    override fun nowMillis(): Long = now

    override suspend fun sleep(millis: Long) {
        synchronized(this) {
            sleeps += millis
            now += millis
        }
    }
}

class FixedRandom(
    private val value: Double = 0.5,
) : RelayRandom {
    override fun unit(): Double = value

    override fun uuid(): UUID = UUID.randomUUID()
}

class StaticTokens(
    private val scopes: Set<RelayScope> = emptySet(),
) : RelayTokenProvider {
    val calls = mutableListOf<Boolean>()

    @Synchronized
    override suspend fun subscriberToken(forceRefresh: Boolean): RelaySubscriberToken {
        calls += forceRefresh
        return RelaySubscriberToken("subscriber-token-${calls.size}", 1_900_000_000_000L, scopes)
    }
}

class CapturingLogger : RelayLogger {
    val messages = mutableListOf<String>()

    override fun log(
        level: RelayLogger.Level,
        message: String,
    ) {
        messages += message
    }
}

class Harness(
    scopes: Set<RelayScope> = emptySet(),
) {
    val server = FakeServer()
    val clock = FakeClock()
    val tokens = StaticTokens(scopes)
    val logger = CapturingLogger()
    val configuration =
        RelayConfiguration(
            baseUrl = "https://relay.test",
            appIdentifier = "app.suiss.example",
            tokenProvider = tokens,
            clock = clock,
            random = FixedRandom(),
            logger = logger,
        )
    val okHttp: OkHttpClient = OkHttpClient.Builder().addInterceptor(server).build()
    val http = RelayHttp(configuration, okHttp)

    fun client(
        context: Context = ApplicationProvider.getApplicationContext(),
        devices: RelayDeviceStorage = MemoryDeviceStorage(),
        settings: RelayNotificationSettings = RelayNotificationSettings(RelayPermission.GRANTED),
        realtime: List<RelayRealtimeTransport> = emptyList(),
    ): RelayClient =
        RelayClient(
            configuration = configuration,
            context = context,
            okHttp = okHttp,
            deviceStorage = devices,
            queueStorage = MemoryIntentQueueStorage(),
            settings = { settings },
            realtimeTransports = realtime,
            scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
            smallIcon = android.R.drawable.ic_dialog_info,
            launchIntent = { null },
        )
}

object Fixtures {
    const val ITEM_ID = "inb_01j9zq3k4m5n6p7q8r9s0t1v2w"
    const val DEVICE_ID = "dev_01j9zq3k4m5n6p7q8r9s0t1v2w"
    const val DELIVERY_ID = "dlv_01j9zq3k4m5n6p7q8r9s0t1v2w"

    fun item(
        id: String = ITEM_ID,
        version: Int = 1,
        read: Boolean = false,
    ): String =
        """{"object":"inbox_item","kind":"personal","id":"$id","state_version":$version,"seen":$read,"read":$read,""" +
            """"archived":false,"hidden":false,"expired":false,"snoozed_until":null,"seen_at":null,"read_at":null,""" +
            """"archived_at":null,"created_at":"2026-11-01T09:30:00Z","last_activity_at":"2026-11-01T09:30:00Z",""" +
            """"category":"orders","tags":[],"severity":null,"group_key":"order-1","title":"Order shipped",""" +
            """"body":"Your order is on its way","avatar_url":null,"url":"https://shop.test/orders/1","actions":[],""" +
            """"data":[],"locale":"en","dir":null,"activity_count":1,"actor_count":0,"expires_at":null}"""

    fun state(
        id: String = ITEM_ID,
        version: Int,
        read: Boolean,
    ): String =
        """{"id":"$id","state_version":$version,"seen":true,"read":$read,"archived":false,"hidden":false,""" +
            """"expired":false,"snoozed_until":null,"seen_at":null,"read_at":null,"archived_at":null}"""

    fun counters(
        unseen: Int,
        unread: Int,
        version: Int,
    ): String = """{"object":"inbox_counters","unseen":$unseen,"unread":$unread,"total":5,"version":$version}"""

    fun device(id: String = DEVICE_ID): String =
        """{"object":"device","id":"$id","subscriber_id":"sub_01j9zq3k4m5n6p7q8r9s0t1v2w","platform":"fcm",""" +
            """"app":"app.suiss.example","token_fingerprint":"0123456789abcdef","apns_environment":null,""" +
            """"permission":"granted","android_channels":[],"locale":"en-US","timezone":"Europe/Istanbul",""" +
            """"state":"active","disabled_reason":null,"registered_at":"2026-11-01T09:30:00Z",""" +
            """"last_seen_at":"2026-11-01T09:30:00Z","deleted_at":null,"created_at":"2026-11-01T09:30:00Z",""" +
            """"updated_at":"2026-11-01T09:30:00Z"}"""

    fun list(
        items: String,
        cursor: String,
        counters: String? = null,
    ): String {
        val counted = counters?.let { ",\"counters\":$it" } ?: ""
        return """{"object":"list","data":[$items],"has_more":false,"next_cursor":null,"previous_cursor":null,"cursor":"$cursor"$counted}"""
    }

    val repositoryRoot: File get() = File(System.getProperty("relay.repoRoot") ?: "../..")
}
