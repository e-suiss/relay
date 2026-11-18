package app.suiss.relay

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.security.MessageDigest
import java.time.Instant
import java.util.concurrent.CancellationException

/** One displayed notification waiting to be reported: the SHA-256 digest of its identifier and when it was shown. */
public data class RelayDisplayedNotification(
    val digest: String,
    val displayedAt: String,
)

/** Runs the reporter's work: a flush started now, and the periodic flush. */
internal interface DisplayedScheduler {
    fun now(block: suspend () -> Unit)

    fun every(
        intervalMillis: Long,
        block: suspend () -> Unit,
    )
}

internal class CoroutineDisplayedScheduler(
    private val scope: CoroutineScope,
) : DisplayedScheduler {
    override fun now(block: suspend () -> Unit) {
        scope.launch { block() }
    }

    override fun every(
        intervalMillis: Long,
        block: suspend () -> Unit,
    ) {
        scope.launch {
            while (isActive) {
                delay(intervalMillis)
                block()
            }
        }
    }
}

// OP-54
// OP-95

/**
 * Opt-in reporting of displayed notifications for client duplicate telemetry. Only the lowercase hex
 * SHA-256 digest of each identifier and the display time leave the device, never the identifier or any
 * content. Reports are batched and sent with the subscriber token when 20 are waiting, every 30 seconds
 * and when the app goes to the background; a failed batch keeps its idempotency key and is retried on the
 * next flush until it is 24 hours old. Disabled unless `RelayConfiguration.reportDisplayedNotifications`
 * is set.
 */
public class RelayDisplayedNotifications internal constructor(
    public val isEnabled: Boolean,
    private val clock: RelayClock,
    private val random: RelayRandom,
    private val scheduler: DisplayedScheduler,
    private val send: suspend (idempotencyKey: String, notifications: List<RelayDisplayedNotification>) -> Unit,
) {
    private class Entry(
        val notification: RelayDisplayedNotification,
        val queuedAtMillis: Long,
    )

    private class Batch(
        val idempotencyKey: String,
        val entries: List<Entry>,
    ) {
        val createdAtMillis: Long = entries.minOf { it.queuedAtMillis }
    }

    private val lock = Any()
    private val flushLock = Mutex()
    private val queued = mutableListOf<Entry>()
    private val batches = ArrayDeque<Batch>()

    init {
        if (isEnabled) scheduler.every(INTERVAL_MILLIS) { flush() }
    }

    /** The reports not yet accepted by Relay, oldest first. */
    public val pending: List<RelayDisplayedNotification>
        get() =
            synchronized(lock) {
                batches.flatMap { batch -> batch.entries.map { it.notification } } + queued.map { it.notification }
            }

    /**
     * Reports that the app displayed the notification with [notificationId] itself. Does nothing when
     * reporting is disabled; the same identifier reported twice is sent twice.
     */
    public fun report(notificationId: String) {
        if (!isEnabled || notificationId.isEmpty()) return
        val now = clock.nowMillis()
        val entry = Entry(RelayDisplayedNotification(digest(notificationId), Instant.ofEpochMilli(now).toString()), now)
        val full =
            synchronized(lock) {
                queued += entry
                queued.size >= BATCH_THRESHOLD
            }
        if (full) scheduler.now { flush() }
    }

    /** Sends the waiting reports now; a batch that fails stays for the next flush with the same idempotency key. */
    public suspend fun flush() {
        if (!isEnabled) return
        flushLock.withLock {
            val ready =
                synchronized(lock) {
                    while (queued.isNotEmpty()) {
                        val chunk = queued.take(MAX_BATCH)
                        batches.addLast(Batch(IdempotencyKey.make(random), chunk))
                        repeat(chunk.size) { queued.removeAt(0) }
                    }
                    val now = clock.nowMillis()
                    batches.removeAll { now - it.createdAtMillis > MAX_AGE_MILLIS }
                    batches.toList()
                }
            for (batch in ready) {
                try {
                    send(batch.idempotencyKey, batch.entries.map { it.notification })
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    return
                }
                synchronized(lock) { batches.remove(batch) }
            }
        }
    }

    internal companion object {
        const val BATCH_THRESHOLD = 20
        const val MAX_BATCH = 100
        const val INTERVAL_MILLIS = 30_000L
        const val MAX_AGE_MILLIS = 24 * 60 * 60 * 1_000L

        fun digest(notificationId: String): String =
            MessageDigest
                .getInstance("SHA-256")
                .digest(notificationId.toByteArray(Charsets.UTF_8))
                .joinToString("") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }

        fun over(
            http: RelayHttp,
            scheduler: DisplayedScheduler,
        ): RelayDisplayedNotifications =
            RelayDisplayedNotifications(
                isEnabled = http.configuration.reportDisplayedNotifications,
                clock = http.configuration.clock,
                random = http.configuration.random,
                scheduler = scheduler,
            ) { key, notifications ->
                val body =
                    mapOf(
                        "notifications" to notifications.map { mapOf("digest" to it.digest, "displayed_at" to it.displayedAt) },
                    )
                http.send(RelayScope.DEVICES_WRITE, "POST", http.url("v1/subscriber/displayed_notifications"), body, key)
            }
    }
}
