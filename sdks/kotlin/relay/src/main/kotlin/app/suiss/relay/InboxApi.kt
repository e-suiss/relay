package app.suiss.relay

import app.suiss.relay.api.model.InboxChanges
import app.suiss.relay.api.model.InboxCounters
import app.suiss.relay.api.model.InboxIntent
import app.suiss.relay.api.model.InboxIntentResult
import app.suiss.relay.api.model.InboxItem
import app.suiss.relay.api.model.InboxItemList
import app.suiss.relay.api.model.InboxItemState
import app.suiss.relay.api.model.InboxReadAll
import app.suiss.relay.api.model.InboxReadAllResult

/** An inbox item as the SDK and its components show it. */
public data class RelayInboxItem(
    val id: String,
    val stateVersion: Int,
    val seen: Boolean = false,
    val read: Boolean = false,
    val archived: Boolean = false,
    val hidden: Boolean = false,
    val expired: Boolean = false,
    val snoozedUntil: String? = null,
    val createdAt: String = "",
    val lastActivityAt: String = createdAt,
    val category: String? = null,
    val groupKey: String? = null,
    val title: String? = null,
    val body: String? = null,
    val url: String? = null,
    val actions: List<Pair<String, String>> = emptyList(),
    val isRightToLeft: Boolean = false,
    val isAnnouncement: Boolean = false,
) {
    /** Whether the item belongs in the inbox tab. */
    val isVisibleInInbox: Boolean get() = !hidden && !expired && !archived && snoozedUntil == null

    /** Applies a server state; an older or equal `state_version` is ignored (IN-5). */
    public fun applying(state: RelayItemState): RelayInboxItem =
        if (state.stateVersion <= stateVersion) {
            this
        } else {
            copy(
                stateVersion = state.stateVersion,
                seen = state.seen,
                read = state.read,
                archived = state.archived,
                hidden = state.hidden,
                expired = state.expired,
            )
        }

    internal companion object {
        fun from(item: InboxItem): RelayInboxItem =
            RelayInboxItem(
                id = item.id,
                stateVersion = item.stateVersion,
                seen = item.seen,
                read = item.read,
                archived = item.archived,
                hidden = item.hidden,
                expired = item.expired,
                snoozedUntil = item.snoozedUntil,
                createdAt = item.createdAt,
                lastActivityAt = item.lastActivityAt,
                category = item.category,
                groupKey = item.groupKey,
                title = item.title,
                body = item.body,
                url = item.url,
                actions = item.actions.map { it.label to it.url },
                isRightToLeft = item.dir?.value == "rtl",
                isAnnouncement = item.kind?.value == "announcement",
            )
    }
}

/** A page of inbox items with the counters and stream cursor of its first page. */
public data class RelayInboxPage(
    val items: List<RelayInboxItem>,
    val hasMore: Boolean,
    val nextCursor: String?,
    val counters: RelayInboxCounters?,
    val streamCursor: String?,
)

/** One change of a delta sync (IN-29). */
public sealed class RelayInboxChange {
    public data class Upsert(
        val item: RelayInboxItem,
    ) : RelayInboxChange()

    public data class Removed(
        val state: RelayItemState,
    ) : RelayInboxChange()
}

/** The answer of a delta sync. */
public data class RelayInboxDelta(
    val changes: List<RelayInboxChange>,
    val cursor: String,
    val hasMore: Boolean,
    val needsColdSync: Boolean,
    val counters: RelayInboxCounters,
)

internal fun InboxCounters.toRelay(): RelayInboxCounters = RelayInboxCounters(unseen, unread, total, version)

internal fun InboxItemState.toRelay(): RelayItemState = RelayItemState(id, stateVersion, seen, read, archived, hidden, expired)

/** The subscriber's own inbox over REST (scopes `inbox:read` and `inbox:write`); writes are intents (IN-12, IN-31). */
public class RelayInboxApi internal constructor(
    private val http: RelayHttp,
) {
    public suspend fun list(
        status: String = "inbox",
        category: String? = null,
        limit: Int? = null,
        startingAfter: String? = null,
    ): RelayInboxPage {
        val url =
            http.url(
                "v1/subscriber/inbox/items",
                mapOf(
                    "status" to status,
                    "category" to category,
                    "limit" to limit?.toString(),
                    "starting_after" to startingAfter,
                ),
            )
        val list = http.decode<InboxItemList>(http.send(RelayScope.INBOX_READ, "GET", url))
        return RelayInboxPage(
            items = list.`data`.map(RelayInboxItem::from),
            hasMore = list.hasMore,
            nextCursor = list.nextCursor,
            counters = list.counters?.toRelay(),
            streamCursor = list.cursor,
        )
    }

    public suspend fun item(id: String): RelayInboxItem =
        RelayInboxItem.from(http.decode<InboxItem>(http.send(RelayScope.INBOX_READ, "GET", http.url("v1/subscriber/inbox/items/$id"))))

    public suspend fun counters(): RelayInboxCounters =
        http.decode<InboxCounters>(http.send(RelayScope.INBOX_READ, "GET", http.url("v1/subscriber/inbox/counters"))).toRelay()

    // IN-29
    public suspend fun changes(
        since: String,
        limit: Int? = null,
    ): RelayInboxDelta {
        val url = http.url("v1/subscriber/inbox/changes", mapOf("since" to since, "limit" to limit?.toString()))
        val delta = http.decode<InboxChanges>(http.send(RelayScope.INBOX_READ, "GET", url))
        val changes =
            delta.changes.map { change ->
                val item = change.item
                if (change.type.value != "removed") {
                    RelayInboxChange.Upsert(
                        RelayInboxItem(
                            id = item.id,
                            stateVersion = item.stateVersion,
                            seen = item.seen,
                            read = item.read,
                            archived = item.archived,
                            hidden = item.hidden,
                            expired = item.expired,
                            snoozedUntil = item.snoozedUntil,
                            createdAt = item.createdAt,
                            lastActivityAt = item.lastActivityAt,
                            category = item.category,
                            groupKey = item.groupKey,
                            title = item.title,
                            body = item.body,
                            url = item.url,
                            isRightToLeft = item.dir?.value == "rtl",
                        ),
                    )
                } else {
                    RelayInboxChange.Removed(
                        RelayItemState(change.itemId, change.stateVersion, item.seen, item.read, item.archived, true, item.expired),
                    )
                }
            }
        return RelayInboxDelta(
            changes = changes,
            cursor = delta.cursor,
            hasMore = delta.hasMore,
            needsColdSync = delta.truncated || delta.resyncRequired,
            counters = delta.counters.toRelay(),
        )
    }

    // IN-14
    public suspend fun markAllRead(category: String? = null): RelayInboxCounters {
        val key = IdempotencyKey.make(http.configuration.random)
        val answer =
            http.send(RelayScope.INBOX_WRITE, "POST", http.url("v1/subscriber/inbox/read_all"), InboxReadAll(category), key)
        return http.decode<InboxReadAllResult>(answer).counters.toRelay()
    }

    // IN-12

    /** Sends one queued intent with the idempotency key it was queued with. */
    public suspend fun send(intent: QueuedIntent): Pair<RelayItemState, RelayInboxCounters> {
        val body =
            InboxIntent(
                op = InboxIntent.Op.entries.first { it.value == intent.operation.wire },
                baseStateVersion = intent.baseStateVersion,
                clientSeq = intent.clientSeq,
                snoozeUntil = intent.snoozeUntil,
            )
        val url = http.url("v1/subscriber/inbox/items/${intent.itemId}/intents")
        val result = http.decode<InboxIntentResult>(http.send(RelayScope.INBOX_WRITE, "POST", url, body, intent.idempotencyKey))
        return result.state.toRelay() to result.counters.toRelay()
    }
}
