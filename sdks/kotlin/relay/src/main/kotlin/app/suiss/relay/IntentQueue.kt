package app.suiss.relay

import android.content.Context
import com.google.gson.Gson
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

// IN-12

/** A state intent on an inbox item. */
public enum class RelayInboxOperation(
    public val wire: String,
) {
    SEEN("seen"),
    READ("read"),
    UNREAD("unread"),
    ARCHIVE("archive"),
    UNARCHIVE("unarchive"),
    HIDE("hide"),
    SNOOZE("snooze"),
    UNSNOOZE("unsnooze"),
    CLICK("click"),
    ;

    /** Reverse intents apply only on the current `state_version`; monotone ones apply unconditionally. */
    public val isReverse: Boolean
        get() = this == UNREAD || this == UNARCHIVE || this == UNSNOOZE
}

// IN-13

/** One intent waiting in the offline queue, with the idempotency key every send of it uses. */
public data class QueuedIntent(
    val itemId: String,
    val operation: RelayInboxOperation,
    val clientSeq: Int,
    val baseStateVersion: Int?,
    val snoozeUntil: String?,
    val idempotencyKey: String,
)

/** The persisted queue: the next `client_seq` and the waiting intents. */
public data class IntentQueueSnapshot(
    val nextSeq: Int = 0,
    val entries: List<QueuedIntent> = emptyList(),
)

/** Where the offline queue survives app restarts. */
public interface IntentQueueStorage {
    public fun load(): IntentQueueSnapshot?

    public fun save(snapshot: IntentQueueSnapshot)
}

/** Keeps the queue in memory only. */
public class MemoryIntentQueueStorage(
    private var snapshot: IntentQueueSnapshot? = null,
) : IntentQueueStorage {
    @Synchronized
    override fun load(): IntentQueueSnapshot? = snapshot

    @Synchronized
    override fun save(snapshot: IntentQueueSnapshot) {
        this.snapshot = snapshot
    }
}

/** Keeps the queue in the app's private shared preferences. */
public class SharedPreferencesIntentQueueStorage(
    context: Context,
) : IntentQueueStorage {
    private val preferences = context.getSharedPreferences("app.suiss.relay.intents", Context.MODE_PRIVATE)
    private val gson = Gson()

    override fun load(): IntentQueueSnapshot? =
        preferences.getString(KEY, null)?.let { runCatching { gson.fromJson(it, IntentQueueSnapshot::class.java) }.getOrNull() }

    override fun save(snapshot: IntentQueueSnapshot) {
        preferences.edit().putString(KEY, gson.toJson(snapshot)).apply()
    }

    private companion object {
        const val KEY = "queue"
    }
}

// IN-13

/**
 * The offline intent queue: ordered by `client_seq` and compacted per item, so only the last intent
 * of an item waits; a reverse intent older than the server state is dropped.
 */
public class IntentQueue(
    private val storage: IntentQueueStorage,
    private val random: RelayRandom = SystemRandom,
) {
    private val mutex = Mutex()
    private var snapshot: IntentQueueSnapshot = storage.load() ?: IntentQueueSnapshot()

    public suspend fun enqueue(
        itemId: String,
        operation: RelayInboxOperation,
        baseStateVersion: Int?,
        snoozeUntil: String? = null,
    ): QueuedIntent =
        mutex.withLock {
            val intent =
                QueuedIntent(
                    itemId = itemId,
                    operation = operation,
                    clientSeq = snapshot.nextSeq,
                    baseStateVersion = baseStateVersion,
                    snoozeUntil = snoozeUntil,
                    idempotencyKey = IdempotencyKey.make(random),
                )
            snapshot =
                IntentQueueSnapshot(
                    nextSeq = snapshot.nextSeq + 1,
                    entries = snapshot.entries.filter { it.itemId != itemId } + intent,
                )
            storage.save(snapshot)
            intent
        }

    public suspend fun pending(): List<QueuedIntent> = mutex.withLock { snapshot.entries.sortedBy { it.clientSeq } }

    public suspend fun remove(clientSeq: Int) {
        mutex.withLock {
            snapshot = snapshot.copy(entries = snapshot.entries.filter { it.clientSeq != clientSeq })
            storage.save(snapshot)
        }
    }

    /**
     * Applies a server state seen through sync or realtime: a waiting reverse intent based on an older
     * `state_version` can no longer win and leaves the queue; monotone intents stay.
     */
    public suspend fun observe(
        itemId: String,
        stateVersion: Int,
    ) {
        mutex.withLock {
            val kept =
                snapshot.entries.filterNot {
                    it.itemId == itemId && it.operation.isReverse && (it.baseStateVersion ?: 0) < stateVersion
                }
            if (kept.size != snapshot.entries.size) {
                snapshot = snapshot.copy(entries = kept)
                storage.save(snapshot)
            }
        }
    }

    public suspend fun isEmpty(): Boolean = mutex.withLock { snapshot.entries.isEmpty() }
}
