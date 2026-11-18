package app.suiss.relay

import app.suiss.relay.api.model.InboxItem
import com.google.gson.Gson
import com.google.gson.JsonObject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** A message the inbox shows once. */
public sealed class RelayInboxNotice {
    /** A reverse change the user just made lost to a newer change on another device (IN-12). */
    public data class UpdatedOnAnotherDevice(
        val itemId: String,
    ) : RelayInboxNotice()
}

/** The inbox state the components observe: items, counters, sync and the offline intent queue. */
public class RelayInboxStore internal constructor(
    private val api: RelayInboxApi,
    internal val queue: IntentQueue,
    private val clock: RelayClock,
    private val scope: CoroutineScope,
) {
    private val mutableItems = MutableStateFlow<List<RelayInboxItem>>(emptyList())
    private val mutableCounters = MutableStateFlow(RelayInboxCounters.ZERO)
    private val mutableNotice = MutableStateFlow<RelayInboxNotice?>(null)
    private val mutableHasMore = MutableStateFlow(false)
    private val mutableError = MutableStateFlow<RelayException?>(null)
    private val drainLock = Mutex()
    private var nextCursor: String? = null
    private val reversals = mutableSetOf<String>()
    private var pendingUndo: Pair<RelayInboxItem, Job>? = null

    public val items: StateFlow<List<RelayInboxItem>> = mutableItems
    public val counters: StateFlow<RelayInboxCounters> = mutableCounters
    public val notice: StateFlow<RelayInboxNotice?> = mutableNotice
    public val hasMore: StateFlow<Boolean> = mutableHasMore
    public val lastError: StateFlow<RelayException?> = mutableError

    /** The stream cursor a delta sync or realtime connection continues from. */
    public var streamCursor: String? = null
        private set

    /** How long hide and archive wait for an undo before they reach the server (IN-15). */
    public var undoWindowMillis: Long = 4_000

    /** Called with the items that became read or left the inbox, to remove their notifications (IN-38). */
    public var onItemsRemoved: (List<RelayInboxItem>) -> Unit = {}

    /** Called the first time the inbox component shows an item, to report it as displayed. */
    public var onItemDisplayed: (RelayInboxItem) -> Unit = {}

    private val displayedIds = mutableSetOf<String>()

    /** Marks [item] as shown by an inbox component; each item counts once per store. */
    public fun markDisplayed(item: RelayInboxItem) {
        val first = synchronized(displayedIds) { displayedIds.add(item.id) }
        if (first) onItemDisplayed(item)
    }

    public fun dismissNotice() {
        mutableNotice.value = null
    }

    // IN-18

    /** Keeps counters only when they are newer than the ones shown. */
    public fun apply(newCounters: RelayInboxCounters) {
        if (newCounters.version > mutableCounters.value.version) mutableCounters.value = newCounters
    }

    public suspend fun refreshCounters() {
        guard { apply(api.counters()) }
    }

    // IN-29

    /** A delta sync from the stream cursor, or a cold sync when there is none or it no longer holds. */
    public suspend fun synchronize() {
        val cursor = streamCursor ?: return coldSync()
        guard {
            var since = cursor
            while (true) {
                val delta = api.changes(since)
                if (delta.needsColdSync) {
                    coldSync()
                    return@guard
                }
                delta.changes.forEach { apply(it) }
                apply(delta.counters)
                since = delta.cursor
                streamCursor = delta.cursor
                if (!delta.hasMore) break
            }
        }
    }

    /** Reads the first page again and replaces the list. */
    public suspend fun coldSync() {
        guard {
            val page = api.list()
            mutableItems.value = page.items.filter { it.isVisibleInInbox }
            mutableHasMore.value = page.hasMore
            nextCursor = page.nextCursor
            page.counters?.let { apply(it) }
            page.streamCursor?.let { streamCursor = it }
            page.items.forEach { queue.observe(it.id, it.stateVersion) }
        }
    }

    public suspend fun loadMore() {
        val cursor = nextCursor ?: return
        guard {
            val page = api.list(startingAfter = cursor)
            val known = mutableItems.value.map { it.id }.toSet()
            mutableItems.value = mutableItems.value + page.items.filter { it.isVisibleInInbox && it.id !in known }
            mutableHasMore.value = page.hasMore
            nextCursor = page.nextCursor
        }
    }

    // IN-26
    // IN-28

    /** Applies one realtime envelope; an item is only replaced by a newer `state_version`. */
    public suspend fun handle(envelope: RelayRealtimeEnvelope) {
        apply(envelope.counters)
        envelope.id?.let { streamCursor = it }
        when (envelope.type) {
            "inbox.item_updated" -> {
                val patch = envelope.itemPatch ?: return
                apply(patch)
                queue.observe(patch.id, patch.stateVersion)
            }

            "inbox.item_created" -> {
                val (json, thin) = envelope.createdItem ?: return
                val item = if (thin) null else decodeItem(json)
                val id = json.string("id") ?: return
                insert(item ?: runCatching { api.item(id) }.getOrNull() ?: return)
            }

            "inbox.items_bulk_updated", "stream.resync_required" -> {
                coldSync()
            }
        }
    }

    // IN-12
    // IN-15

    /** Applies an intent on screen at once, queues it and sends it; hide and archive wait for the undo window first. */
    public suspend fun perform(
        operation: RelayInboxOperation,
        item: RelayInboxItem,
        snoozeUntil: String? = null,
    ) {
        if (operation.isReverse) reversals += item.id
        applyOptimistic(operation, item.id)
        if (operation == RelayInboxOperation.ARCHIVE || operation == RelayInboxOperation.HIDE) {
            pendingUndo?.second?.cancel()
            val job =
                scope.launch {
                    clock.sleep(undoWindowMillis)
                    commit(operation, item, snoozeUntil)
                }
            pendingUndo = item to job
            return
        }
        commit(operation, item, snoozeUntil)
    }

    // AG-26
    // AG-32
    // AG-35

    /**
     * Sends the option the user chose as the response to the item's waitpoint and shows the receipt.
     * An approval is never answered here (IN-6); a refused response puts the waitpoint back as it was.
     */
    public suspend fun respond(
        item: RelayInboxItem,
        option: RelayWaitpointOption,
    ) {
        val waitpoint = item.waitpoint ?: return
        if (item.isApproval || !waitpoint.acceptsResponse || option !in waitpoint.options) return
        val digest = waitpoint.subjectDigest ?: return
        updateWaitpoint(item.id) { it.copy(status = RelayWaitpointStatus.PROCESSING) }
        try {
            val receipt = api.respond(waitpoint.id, option.value, digest)
            updateWaitpoint(item.id) { receipt.applyTo(it) }
        } catch (error: RelayException) {
            updateWaitpoint(item.id) { it.copy(status = waitpoint.status) }
            mutableError.value = error
        }
    }

    /** Takes back the last hide or archive before it reached the server. */
    public fun undo() {
        val (item, job) = pendingUndo ?: return
        job.cancel()
        pendingUndo = null
        insert(item, force = true)
    }

    public suspend fun markAllRead() {
        val unread = mutableItems.value.filter { !it.read }
        mutableItems.value = mutableItems.value.map { it.copy(read = true, seen = true) }
        guard {
            apply(api.markAllRead())
            onItemsRemoved(unread)
        }
    }

    /** Marks the items the user saw (IN-9). */
    public suspend fun markSeen(visible: List<RelayInboxItem>) {
        val unseen = visible.filter { !it.seen }
        if (unseen.isEmpty()) return
        unseen.forEach {
            applyOptimistic(RelayInboxOperation.SEEN, it.id)
            queue.enqueue(it.id, RelayInboxOperation.SEEN, it.stateVersion)
        }
        drainQueue()
    }

    // IN-13

    /**
     * Sends the waiting intents in `client_seq` order. A conflict is accepted silently; the notice appears
     * only when the user made that reverse change in this session.
     */
    public suspend fun drainQueue() {
        if (!drainLock.tryLock()) return
        try {
            for (intent in queue.pending()) {
                try {
                    val (state, newCounters) = api.send(intent)
                    queue.remove(intent.clientSeq)
                    apply(state)
                    apply(newCounters)
                } catch (error: RelayException) {
                    val problem = (error as? RelayException.Problem)?.problem
                    if (problem?.code == "inbox_item_conflict") {
                        queue.remove(intent.clientSeq)
                        problem.current?.let { apply(it) }
                        if (intent.operation.isReverse && intent.itemId in reversals) {
                            mutableNotice.value = RelayInboxNotice.UpdatedOnAnotherDevice(intent.itemId)
                        }
                        continue
                    }
                    mutableError.value = error
                    if (error.isRetryable) return
                    queue.remove(intent.clientSeq)
                }
            }
            reversals.clear()
        } finally {
            drainLock.unlock()
        }
    }

    private suspend fun commit(
        operation: RelayInboxOperation,
        item: RelayInboxItem,
        snoozeUntil: String?,
    ) {
        if (pendingUndo?.first?.id == item.id) pendingUndo = null
        queue.enqueue(item.id, operation, item.stateVersion, snoozeUntil)
        drainQueue()
    }

    private fun applyOptimistic(
        operation: RelayInboxOperation,
        id: String,
    ) {
        val list = mutableItems.value
        val index = list.indexOfFirst { it.id == id }
        if (index < 0) return
        val item = list[index]
        var counters = mutableCounters.value
        val updated =
            when (operation) {
                RelayInboxOperation.SEEN -> {
                    if (!item.seen) counters = counters.copy(unseen = maxOf(0, counters.unseen - 1))
                    item.copy(seen = true)
                }

                RelayInboxOperation.READ, RelayInboxOperation.CLICK -> {
                    if (!item.seen) counters = counters.copy(unseen = maxOf(0, counters.unseen - 1))
                    if (!item.read) counters = counters.copy(unread = maxOf(0, counters.unread - 1))
                    item.copy(seen = true, read = true)
                }

                RelayInboxOperation.UNREAD -> {
                    if (item.read) counters = counters.copy(unread = counters.unread + 1)
                    item.copy(read = false)
                }

                RelayInboxOperation.ARCHIVE -> {
                    item.copy(archived = true)
                }

                RelayInboxOperation.UNARCHIVE -> {
                    item.copy(archived = false)
                }

                RelayInboxOperation.HIDE -> {
                    item.copy(hidden = true)
                }

                RelayInboxOperation.SNOOZE -> {
                    item.copy(snoozedUntil = "snoozed")
                }

                RelayInboxOperation.UNSNOOZE -> {
                    item.copy(snoozedUntil = null)
                }
            }
        mutableCounters.value = counters
        replace(index, updated, wasRead = item.read)
    }

    private suspend fun apply(change: RelayInboxChange) {
        when (change) {
            is RelayInboxChange.Upsert -> {
                queue.observe(change.item.id, change.item.stateVersion)
                insert(change.item)
            }

            is RelayInboxChange.Removed -> {
                queue.observe(change.state.id, change.state.stateVersion)
                val removed = mutableItems.value.firstOrNull { it.id == change.state.id } ?: return
                mutableItems.value = mutableItems.value - removed
                onItemsRemoved(listOf(removed))
            }
        }
    }

    private fun apply(state: RelayItemState) {
        val index = mutableItems.value.indexOfFirst { it.id == state.id }
        if (index < 0) return
        val item = mutableItems.value[index]
        replace(index, item.applying(state), wasRead = item.read)
    }

    private fun apply(patch: RelayItemPatch) {
        val index = mutableItems.value.indexOfFirst { it.id == patch.id }
        if (index < 0) return
        val item = mutableItems.value[index]
        if (patch.stateVersion <= item.stateVersion) return
        val updated =
            item.copy(
                stateVersion = patch.stateVersion,
                seen = patch.seen ?: item.seen,
                read = patch.read ?: item.read,
                archived = patch.archived ?: item.archived,
                hidden = patch.hidden ?: item.hidden,
                expired = patch.expired ?: item.expired,
            )
        replace(index, updated, wasRead = item.read)
    }

    private fun replace(
        index: Int,
        updated: RelayInboxItem,
        wasRead: Boolean,
    ) {
        val list = mutableItems.value.toMutableList()
        if (updated.isVisibleInInbox) {
            list[index] = updated
            mutableItems.value = list
            if (updated.read && !wasRead) onItemsRemoved(listOf(updated))
        } else {
            list.removeAt(index)
            mutableItems.value = list
            onItemsRemoved(listOf(updated))
        }
    }

    private fun updateWaitpoint(
        itemId: String,
        change: (RelayWaitpoint) -> RelayWaitpoint,
    ) {
        mutableItems.value =
            mutableItems.value.map { item ->
                val waitpoint = item.waitpoint
                if (item.id == itemId && waitpoint != null) item.copy(waitpoint = change(waitpoint)) else item
            }
    }

    private fun insert(
        item: RelayInboxItem,
        force: Boolean = false,
    ) {
        val list = mutableItems.value.toMutableList()
        val index = list.indexOfFirst { it.id == item.id }
        if (index >= 0) {
            if (!force && item.stateVersion <= list[index].stateVersion) return
            if (item.isVisibleInInbox || force) list[index] = item else list.removeAt(index)
        } else {
            if (!item.isVisibleInInbox && !force) return
            list += item
            list.sortByDescending { it.lastActivityAt }
        }
        mutableItems.value = list
    }

    private suspend fun guard(block: suspend () -> Unit) {
        try {
            block()
        } catch (error: RelayException) {
            mutableError.value = error
        }
    }

    internal companion object {
        private val gson = Gson()

        fun decodeItem(json: JsonObject): RelayInboxItem? =
            runCatching { RelayInboxItem.from(gson.fromJson(json, InboxItem::class.java)) }.getOrNull()
    }
}
