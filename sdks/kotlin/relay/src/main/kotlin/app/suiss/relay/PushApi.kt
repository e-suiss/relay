package app.suiss.relay

import android.content.Context
import app.suiss.relay.api.model.AndroidChannel
import app.suiss.relay.api.model.AndroidChannelImportance
import app.suiss.relay.api.model.Device
import app.suiss.relay.api.model.DevicePermission
import app.suiss.relay.api.model.DevicePlatform
import app.suiss.relay.api.model.DeviceRegistration
import app.suiss.relay.api.model.DeviceStatusWrite
import app.suiss.relay.api.model.DeviceStatusWriteSignals
import app.suiss.relay.api.model.PushReceipt
import java.time.Instant
import java.util.Locale
import java.util.TimeZone

// CH-33
// IN-35

/** The Relay part of a push: the opaque identifier, topic and link, or a sync signal. */
public data class RelayPushPayload(
    val id: String?,
    val topic: String? = null,
    val url: String? = null,
    val isSyncSignal: Boolean = false,
    val counterVersion: Int? = null,
    val neutralTitle: String? = null,
    val neutralBody: String? = null,
) {
    /** The delivery the push belongs to, when the identifier is a delivery id. */
    val deliveryId: String? get() = id?.takeIf { it.startsWith("dlv_") }

    /** The inbox item the push shows, when the identifier is an inbox item id. */
    val itemId: String? get() = id?.takeIf { it.startsWith("inb_") || it.startsWith("ann_") }

    public companion object {
        /** Reads FCM or HMS data members (`relay_id`, `relay_topic`, `relay_url`, the neutral texts, `sync`). */
        public fun from(data: Map<String, String>): RelayPushPayload? {
            val id = data["relay_id"]
            val sync = data["sync"] == "true" || data["relay_sync"] == "true"
            if (id == null && !sync) return null
            return RelayPushPayload(
                id = id,
                topic = data["relay_topic"],
                url = data["relay_url"],
                isSyncSignal = sync,
                counterVersion = (data["counter_version"] ?: data["relay_counter_version"])?.toIntOrNull(),
                neutralTitle = data["relay_neutral_title"],
                neutralBody = data["relay_neutral_body"],
            )
        }
    }
}

/** What the SDK remembers about this device's registration; the push token is not a secret. */
public data class RelayDeviceRecord(
    val deviceId: String,
    val token: String,
)

/** Where the device registration survives app restarts. */
public interface RelayDeviceStorage {
    public fun load(): RelayDeviceRecord?

    public fun save(record: RelayDeviceRecord?)
}

/** Keeps the registration in memory only. */
public class MemoryDeviceStorage(
    private var record: RelayDeviceRecord? = null,
) : RelayDeviceStorage {
    @Synchronized
    override fun load(): RelayDeviceRecord? = record

    @Synchronized
    override fun save(record: RelayDeviceRecord?) {
        this.record = record
    }
}

/** Keeps the registration in the app's private shared preferences. */
public class SharedPreferencesDeviceStorage(
    context: Context,
) : RelayDeviceStorage {
    private val preferences = context.getSharedPreferences("app.suiss.relay.device", Context.MODE_PRIVATE)

    override fun load(): RelayDeviceRecord? {
        val id = preferences.getString("device_id", null) ?: return null
        val token = preferences.getString("token", null) ?: return null
        return RelayDeviceRecord(id, token)
    }

    override fun save(record: RelayDeviceRecord?) {
        val editor = preferences.edit()
        if (record == null) {
            editor.clear()
        } else {
            editor.putString("device_id", record.deviceId).putString("token", record.token)
        }
        editor.apply()
    }
}

/** The push service a token belongs to. */
public enum class RelayPushPlatform(
    public val wire: String,
) {
    FCM("fcm"),
    HMS("hms"),
}

/** A push receipt of the SDK; it is evidence beside the provider's acceptance (CH-32). */
public enum class RelayReceipt(
    public val wire: String,
) {
    DISPLAYED("displayed"),
    CLICKED("clicked"),
}

/** A device status signal of the versioned dictionary (IN-47). */
public enum class RelayDeviceSignal { WORN, LOCKED, HEADPHONES, FOCUS, BREAK }

// X-31

/**
 * Push device registration, receipts and device status for the token's own subscriber (scopes
 * `devices:write` and `presence:write`). It never writes the subscriber profile or consents.
 */
public class RelayPushApi internal constructor(
    private val http: RelayHttp,
    private val storage: RelayDeviceStorage,
    private val settings: RelayNotificationSettingsReader,
    private val channels: () -> List<Pair<String, String>>,
) {
    /** The registered device, when there is one. */
    public val device: RelayDeviceRecord? get() = storage.load()

    // CH-28
    // CH-31

    /**
     * Registers or refreshes the push token with the current permission and channel importances; call
     * it on every app start and from `onNewToken`. A changed token names the token it replaces.
     */
    public suspend fun register(
        token: String,
        platform: RelayPushPlatform = RelayPushPlatform.FCM,
    ): String {
        val current = settings.read()
        val previous = storage.load()?.token?.takeIf { it != token }
        val reported =
            channels().mapNotNull { (id, importance) ->
                AndroidChannelImportance.entries.firstOrNull { it.value == importance }?.let { AndroidChannel(id, it) }
            }
        val registration =
            DeviceRegistration(
                app = http.configuration.appIdentifier,
                permission = DevicePermission.entries.first { it.value == current.permission.wire },
                platform = DevicePlatform.entries.first { it.value == platform.wire },
                token = token,
                androidChannels = reported.toSet().takeIf { it.isNotEmpty() },
                locale = DeviceContext.locale(),
                previousToken = previous,
                timezone = DeviceContext.timeZone(),
            )
        val key = IdempotencyKey.make(http.configuration.random)
        val answer = http.send(RelayScope.DEVICES_WRITE, "POST", http.url("v1/subscriber/devices"), registration, key)
        val device = http.decode<Device>(answer)
        storage.save(RelayDeviceRecord(device.id, token))
        http.configuration.logger.log(RelayLogger.Level.INFO, "push device registered")
        return device.id
    }

    /** Sends the stored token again with the current permission and channels (every app start, CH-28). */
    public suspend fun refreshRegistration(platform: RelayPushPlatform = RelayPushPlatform.FCM) {
        val record = storage.load() ?: return
        register(record.token, platform)
    }

    /** Disables this device on logout; preferences stay (CH-31, PC-16). */
    public suspend fun unregister() {
        val record = storage.load() ?: return
        val key = IdempotencyKey.make(http.configuration.random)
        try {
            http.send(RelayScope.DEVICES_WRITE, "DELETE", http.url("v1/subscriber/devices/${record.deviceId}"), null, key)
        } catch (error: RelayException.Problem) {
            if (error.problem.status != 404) throw error
        }
        storage.save(null)
    }

    // CH-32

    /** Records that a push was displayed or clicked. */
    public suspend fun record(
        receipt: RelayReceipt,
        deliveryId: String,
    ) {
        val body =
            PushReceipt(
                deliveryId = deliveryId,
                receipt = PushReceipt.Receipt.entries.first { it.value == receipt.wire },
                occurredAt = Instant.ofEpochMilli(http.configuration.clock.nowMillis()).toString(),
            )
        val key = IdempotencyKey.make(http.configuration.random)
        http.send(RelayScope.DEVICES_WRITE, "POST", http.url("v1/subscriber/push_receipts"), body, key)
    }

    // IN-47
    // IN-48

    /**
     * Writes the changed status signals of this device with a time to live. The values are personal
     * data: they are never logged and never kept by the SDK.
     */
    public suspend fun updateStatus(
        signals: Map<RelayDeviceSignal, Boolean>,
        ttlSeconds: Long = 300,
    ) {
        if (signals.isEmpty()) return
        val record = storage.load() ?: throw RelayException.NotRegistered()
        val body =
            DeviceStatusWrite(
                signals =
                    DeviceStatusWriteSignals(
                        `break` = signals[RelayDeviceSignal.BREAK],
                        focus = signals[RelayDeviceSignal.FOCUS],
                        headphones = signals[RelayDeviceSignal.HEADPHONES],
                        locked = signals[RelayDeviceSignal.LOCKED],
                        worn = signals[RelayDeviceSignal.WORN],
                    ),
                version = DeviceStatusWrite.Version.V1,
                ttl = "PT${ttlSeconds.coerceIn(1, 900)}S",
            )
        http.send(RelayScope.PRESENCE_WRITE, "PATCH", http.url("v1/subscriber/devices/${record.deviceId}/status"), body)
        http.configuration.logger.log(RelayLogger.Level.DEBUG, "device status written")
    }

    // CH-33

    /**
     * Fetches the content of a content-free push over TLS. `null` means the generic text stays: no
     * network, no time left, no permission or an identifier that does not name an inbox item.
     */
    public suspend fun content(payload: RelayPushPayload): RelayInboxItem? {
        val itemId = payload.itemId ?: return null
        return runCatching { RelayInboxApi(http).item(itemId) }.getOrNull()
    }
}

/** The locale and time zone a device reports with its registration. */
internal object DeviceContext {
    private val localePattern = Regex("^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$")
    private val zonePattern = Regex("^[A-Za-z]+(/[A-Za-z0-9_+-]+)*$")

    fun locale(locale: Locale = Locale.getDefault()): String? =
        locale.toLanguageTag().takeIf { it.length <= 35 && localePattern.matches(it) }

    fun timeZone(zone: TimeZone = TimeZone.getDefault()): String? {
        val id = zone.id
        val rejected = id == "UTC" || id.startsWith("GMT") || id.startsWith("Etc/")
        return id.takeIf { !rejected && zonePattern.matches(it) }
    }
}
