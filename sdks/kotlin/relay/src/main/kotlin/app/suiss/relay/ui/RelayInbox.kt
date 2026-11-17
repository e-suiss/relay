package app.suiss.relay.ui

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
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
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
import kotlinx.coroutines.launch

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

/** One inbox row with its actions. */
@Composable
public fun RelayInboxRow(
    item: RelayInboxItem,
    onOpen: () -> Unit,
    onToggleRead: () -> Unit,
    onArchive: () -> Unit,
    onHide: () -> Unit,
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
                    item.title?.let {
                        Text(it, color = theme.primaryText, fontWeight = if (item.read) FontWeight.Normal else FontWeight.Bold)
                    }
                    item.body?.let { Text(it, color = theme.secondaryText, maxLines = 3) }
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
