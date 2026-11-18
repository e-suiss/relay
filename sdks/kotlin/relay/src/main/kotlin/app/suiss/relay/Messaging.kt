package app.suiss.relay

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import java.util.Locale

// CH-33

/** The generic text shown when the content of a content-free push cannot be fetched. */
public object RelayNeutralText {
    public fun title(locale: Locale = Locale.getDefault()): String = if (isTurkish(locale)) "Yeni bildirim" else "New notification"

    public fun body(locale: Locale = Locale.getDefault()): String =
        if (isTurkish(locale)) "Yeni bir bildiriminiz var." else "You have a new notification."

    private fun isTurkish(locale: Locale): Boolean = locale.language == "tr"
}

/** A notification the data-message handler decided to show. */
public data class RelayShownNotification(
    val tag: String,
    val channelId: String,
    val title: String,
    val body: String,
    val fetched: Boolean,
    val subtitle: String? = null,
)

// CH-33
// IN-35

/**
 * Handles Relay FCM or HMS data messages from the app's messaging service. A sync signal refreshes the
 * counters and runs a delta sync; a content-free push fetches its content by its delivery id over TLS
 * and shows it, or shows the generic text when the content cannot be read. The content never falls back into the
 * push payload.
 */
public class RelayDataMessageHandler internal constructor(
    private val context: Context,
    private val push: RelayPushApi,
    private val onSync: suspend () -> Unit,
    private val smallIcon: Int,
    private val launchIntent: () -> Intent?,
    private val displayed: RelayDisplayedNotifications? = null,
) {
    /** Handles one data message; returns what was shown, or `null` for a sync signal or a foreign message. */
    public suspend fun handle(
        data: Map<String, String>,
        locale: Locale = Locale.getDefault(),
    ): RelayShownNotification? {
        val payload = RelayPushPayload.from(data) ?: return null
        if (payload.isSyncSignal) {
            onSync()
            return null
        }
        payload.deliveryId?.let { runCatching { push.record(RelayReceipt.DISPLAYED, it) } }
        val content = push.pushContent(payload)
        val item = if (content == null) push.content(payload) else null
        val title = content?.title ?: item?.title
        val body = content?.body ?: item?.body
        val fetched = title != null || body != null
        val category = item?.category?.takeIf { fetched } ?: RelayNotificationChannels.GENERAL_CATEGORY
        val manager = context.getSystemService(NotificationManager::class.java)
        val preferred = RelayNotificationChannels.channelId(category, RelayInterruptionLevel.ACTIVE)
        val channelId =
            if (manager?.getNotificationChannel(preferred) != null) {
                preferred
            } else {
                RelayNotificationChannels.channelId(RelayNotificationChannels.GENERAL_CATEGORY, RelayInterruptionLevel.ACTIVE)
            }
        val shown =
            RelayShownNotification(
                tag = payload.id ?: "relay",
                channelId = channelId,
                title = if (fetched) title.orEmpty() else payload.neutralTitle ?: RelayNeutralText.title(locale),
                body = if (fetched) body.orEmpty() else payload.neutralBody ?: RelayNeutralText.body(locale),
                fetched = fetched,
                subtitle = content?.subtitle?.takeIf { fetched },
            )
        val builder =
            NotificationCompat
                .Builder(context, shown.channelId)
                .setSmallIcon(smallIcon)
                .setContentTitle(shown.title)
                .setContentText(shown.body)
                .setAutoCancel(true)
                .setGroup(payload.topic ?: item?.groupKey)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
        shown.subtitle?.let { builder.setSubText(it) }
        launchIntent()?.let { intent ->
            data.forEach { (key, value) -> if (key.startsWith("relay_")) intent.putExtra(key, value) }
            content?.url?.takeIf { fetched && "relay_url" !in data }?.let { intent.putExtra("relay_url", it) }
            val pending =
                PendingIntent.getActivity(
                    context,
                    shown.tag.hashCode(),
                    intent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
            builder.setContentIntent(pending)
        }
        manager?.notify(shown.tag, TAG_ID, builder.build())
        (content?.notificationId ?: payload.id)?.let { displayed?.report(it) }
        return shown
    }

    internal companion object {
        const val TAG_ID = 0x52454c
    }
}

// IN-38

/** Removes the shown notifications of items read or removed on any device. */
public class RelayNotificationRemover(
    private val context: Context,
) {
    public fun remove(items: List<RelayInboxItem>) {
        if (items.isEmpty()) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val ids = items.map { it.id }.toSet()
        val groups = items.mapNotNull { it.groupKey }.toSet()
        manager.activeNotifications
            .filter { it.id == RelayDataMessageHandler.TAG_ID }
            .filter { (it.tag != null && it.tag in ids) || (it.notification.group != null && it.notification.group in groups) }
            .forEach { manager.cancel(it.tag, it.id) }
    }

    /** Removes every shown Relay notification once nothing is unread. */
    public fun removeAll() {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.activeNotifications.filter { it.id == RelayDataMessageHandler.TAG_ID }.forEach { manager.cancel(it.tag, it.id) }
    }
}
