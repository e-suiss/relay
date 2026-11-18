package app.suiss.relay.ui

import android.content.res.Resources
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import app.suiss.relay.R
import app.suiss.relay.RelayInboxItem
import app.suiss.relay.RelayInboxNotice
import app.suiss.relay.RelayInboxOperation
import app.suiss.relay.RelayInboxStore
import app.suiss.relay.RelayWaitpoint
import app.suiss.relay.RelayWaitpointOption
import app.suiss.relay.RelayWaitpointResponder
import app.suiss.relay.RelayWaitpointStatus
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

// X-32

/** A bell with the unseen badge; its accessibility label reads the count. */
@Composable
public fun RelayBell(
    store: RelayInboxStore,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: @Composable () -> Unit = { Text(stringResource(R.string.relay_bell_label_none)) },
) {
    val theme = LocalRelayTheme.current
    val counters by store.counters.collectAsState()
    val label =
        if (counters.unseen > 0) {
            stringResource(R.string.relay_bell_label, counters.unseen)
        } else {
            stringResource(R.string.relay_bell_label_none)
        }
    Box(
        modifier =
            modifier
                .defaultMinSize(minWidth = 48.dp, minHeight = 48.dp)
                .clickable(role = Role.Button, onClick = onClick)
                .semantics(mergeDescendants = true) { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        icon()
        if (counters.unseen > 0) {
            Text(
                text = if (counters.unseen > 99) "99+" else counters.unseen.toString(),
                color = theme.onAccent,
                modifier =
                    Modifier
                        .align(Alignment.TopEnd)
                        .background(theme.unreadIndicator, CircleShape)
                        .padding(horizontal = 5.dp, vertical = 1.dp),
            )
        }
    }
}

// X-32
// X-6

/**
 * The inbox list: unread items are marked by a dot, a bold title and their accessibility state, never
 * by colour alone; actions send read, unread, archive and hide intents.
 */
@Composable
public fun RelayInbox(
    store: RelayInboxStore,
    modifier: Modifier = Modifier,
) {
    val theme = LocalRelayTheme.current
    val items by store.items.collectAsState()
    val counters by store.counters.collectAsState()
    val hasMore by store.hasMore.collectAsState()
    val notice by store.notice.collectAsState()
    val scope = rememberCoroutineScope()
    val uriHandler = LocalUriHandler.current
    Column(modifier = modifier.background(theme.background)) {
        Row(modifier = Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.relay_inbox_title), color = theme.primaryText, fontWeight = FontWeight.Bold)
            Spacer(Modifier.weight(1f))
            TextButton(onClick = { scope.launch { store.markAllRead() } }, enabled = counters.unread > 0) {
                Text(stringResource(R.string.relay_inbox_mark_all_read), color = theme.accent)
            }
        }
        if (notice is RelayInboxNotice.UpdatedOnAnotherDevice) {
            Row(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.relay_inbox_updated_elsewhere), color = theme.secondaryText)
                Spacer(Modifier.weight(1f))
                TextButton(onClick = { store.dismissNotice() }) { Text(stringResource(R.string.relay_prefs_cancel)) }
            }
        }
        if (items.isEmpty()) {
            Text(
                stringResource(R.string.relay_inbox_empty),
                color = theme.secondaryText,
                modifier = Modifier.fillMaxWidth().padding(32.dp),
            )
        }
        LazyColumn(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            items(items, key = { it.id }) { item ->
                LaunchedEffect(item.id) { store.markSeen(listOf(item)) }
                RelayInboxRow(
                    item = item,
                    onOpen = {
                        scope.launch { store.perform(RelayInboxOperation.CLICK, item) }
                        item.url?.let { runCatching { uriHandler.openUri(it) } }
                    },
                    onToggleRead = {
                        scope.launch { store.perform(if (item.read) RelayInboxOperation.UNREAD else RelayInboxOperation.READ, item) }
                    },
                    onArchive = { scope.launch { store.perform(RelayInboxOperation.ARCHIVE, item) } },
                    onHide = { scope.launch { store.perform(RelayInboxOperation.HIDE, item) } },
                    onRespond = { option -> scope.launch { store.respond(item, option) } },
                    onOpenApproval = { url -> runCatching { uriHandler.openUri(url) } },
                )
            }
            if (hasMore) {
                item {
                    TextButton(onClick = { scope.launch { store.loadMore() } }) {
                        Text(stringResource(R.string.relay_inbox_load_more), color = theme.accent)
                    }
                }
            }
        }
    }
}

// AG-34
// AG-35
// X-6

/**
 * One inbox row with its actions. An item from an AI agent carries the agent label; a waitpoint shows
 * its state and, while it awaits a response, its options; an approval only links to Access.
 */
@Composable
public fun RelayInboxRow(
    item: RelayInboxItem,
    onOpen: () -> Unit,
    onToggleRead: () -> Unit,
    onArchive: () -> Unit,
    onHide: () -> Unit,
    onRespond: (RelayWaitpointOption) -> Unit = {},
    onOpenApproval: (String) -> Unit = {},
) {
    val theme = LocalRelayTheme.current
    val unread = stringResource(R.string.relay_inbox_unread)
    Column(
        modifier =
            Modifier
                .fillMaxWidth()
                .clickable(role = Role.Button, onClick = onOpen)
                .padding(horizontal = 16.dp, vertical = 8.dp)
                .semantics(mergeDescendants = true) { if (!item.read) stateDescription = unread },
    ) {
        Row(verticalAlignment = Alignment.Top) {
            Box(
                modifier =
                    Modifier
                        .padding(top = 6.dp)
                        .size(8.dp)
                        .background(if (item.read) androidx.compose.ui.graphics.Color.Transparent else theme.unreadIndicator, CircleShape),
            )
            Spacer(Modifier.width(12.dp))
            androidx.compose.runtime.CompositionLocalProvider(
                androidx.compose.ui.platform.LocalLayoutDirection provides
                    if (item.isRightToLeft) LayoutDirection.Rtl else LayoutDirection.Ltr,
            ) {
                Column {
                    if (item.isFromAgent) Text(stringResource(R.string.relay_inbox_sender_agent), color = theme.secondaryText)
                    item.title?.let {
                        Text(it, color = theme.primaryText, fontWeight = if (item.read) FontWeight.Normal else FontWeight.Bold)
                    }
                    item.body?.let { Text(it, color = theme.secondaryText, maxLines = 3) }
                    if (item.waitpoint != null || item.isApproval) RelayWaitpointPanel(item, onRespond, onOpenApproval)
                }
            }
        }
        Row {
            TextButton(onClick = onToggleRead) {
                Text(
                    stringResource(if (item.read) R.string.relay_inbox_mark_unread else R.string.relay_inbox_mark_read),
                    color = theme.accent,
                )
            }
            TextButton(onClick = onArchive) { Text(stringResource(R.string.relay_inbox_archive), color = theme.accent) }
            TextButton(onClick = onHide) { Text(stringResource(R.string.relay_inbox_hide), color = theme.destructive) }
        }
    }
}

// AG-32
// AG-35
// IN-6

/**
 * The waitpoint of an item: awaiting with its options as buttons, processing, responded (who and when)
 * or not awaited any more. An approval has no answer buttons, only the link to the Access approval
 * surface.
 */
@Composable
public fun RelayWaitpointPanel(
    item: RelayInboxItem,
    onRespond: (RelayWaitpointOption) -> Unit,
    onOpenApproval: (String) -> Unit,
) {
    val theme = LocalRelayTheme.current
    val waitpoint = item.waitpoint
    val resources = LocalContext.current.resources
    val locale = LocalConfiguration.current.locales[0] ?: Locale.getDefault()
    Column(modifier = Modifier.padding(top = 4.dp)) {
        if (waitpoint != null && !(item.isApproval && waitpoint.status == RelayWaitpointStatus.AWAITING)) {
            Text(
                waitpointStatusText(waitpoint, resources, locale),
                color = theme.secondaryText,
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            )
        }
        if (item.isApproval) {
            Text(stringResource(R.string.relay_inbox_approval_note), color = theme.secondaryText)
            val url = waitpoint?.takeIf { it.status == RelayWaitpointStatus.AWAITING }?.approvalUrl
            if (url != null) {
                TextButton(onClick = { onOpenApproval(url) }) {
                    Text(stringResource(R.string.relay_inbox_approval_open), color = theme.accent)
                }
            }
        } else if (waitpoint != null && waitpoint.acceptsResponse) {
            waitpoint.options.forEach { option ->
                TextButton(onClick = { onRespond(option) }) { Text(option.label, color = theme.accent) }
            }
        }
    }
}

// AG-35

/** The status line of a waitpoint in the given resources' language. */
internal fun waitpointStatusText(
    waitpoint: RelayWaitpoint,
    resources: Resources,
    locale: Locale,
    zone: ZoneId = ZoneId.systemDefault(),
): String =
    when (waitpoint.status) {
        RelayWaitpointStatus.AWAITING -> {
            resources.getString(R.string.relay_inbox_awaiting)
        }

        RelayWaitpointStatus.PROCESSING -> {
            resources.getString(R.string.relay_inbox_processing)
        }

        RelayWaitpointStatus.RESPONDED -> {
            val who = responderName(waitpoint.responder, resources)
            val time = waitpoint.respondedAt?.let { formatTime(it, locale, zone) }
            if (time != null) {
                resources.getString(R.string.relay_inbox_answered_by, who, time)
            } else {
                resources.getString(R.string.relay_inbox_answered, who)
            }
        }

        RelayWaitpointStatus.NOT_AWAITED -> {
            resources.getString(R.string.relay_inbox_not_awaited)
        }
    }

internal fun responderName(
    responder: RelayWaitpointResponder?,
    resources: Resources,
): String =
    when {
        responder == null -> resources.getString(R.string.relay_inbox_who_someone)
        responder.isAgent -> resources.getString(R.string.relay_inbox_who_agent)
        else -> resources.getString(R.string.relay_inbox_who_you)
    }

internal fun formatTime(
    timestamp: String,
    locale: Locale,
    zone: ZoneId,
): String? =
    runCatching {
        DateTimeFormatter
            .ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
            .withLocale(locale)
            .withZone(zone)
            .format(Instant.parse(timestamp))
    }.getOrNull()
