package app.suiss.relay

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationChannelGroup
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build

/** The message classes of Relay categories. */
public enum class RelayMessageClass(
    public val wire: String,
) {
    SECURITY("security"),
    ACTION_REQUIRED("action_required"),
    TRANSACTIONAL("transactional"),
    OPERATIONAL("operational"),
    SOCIAL("social"),
    MARKETING("marketing"),
    SYSTEM("system"),
}

/** The four interruption levels (CH-65). */
public enum class RelayInterruptionLevel(
    public val wire: String,
) {
    PASSIVE("passive"),
    ACTIVE("active"),
    TIME_SENSITIVE("time-sensitive"),
    CRITICAL("critical"),
}

/** What the host app knows about a category: its name, class and whether a digest is allowed. */
public data class RelayCategoryInfo(
    val key: String,
    val name: String,
    val messageClass: RelayMessageClass,
    val digestAllowed: Boolean = false,
) {
    /** Social categories always allow a digest (PC-17). */
    val allowsDigest: Boolean get() = digestAllowed || messageClass == RelayMessageClass.SOCIAL
}

/** An Android channel the SDK creates for a category at one interruption level. */
public data class RelayChannelSpec(
    val id: String,
    val category: String,
    val level: RelayInterruptionLevel,
    val importance: Int,
)

// CH-30
// CH-65

/**
 * The category × level notification channels. Channel ids are `relay.<category>.<level>` and never
 * change between releases, because Android does not let code raise a channel's importance later.
 */
public object RelayNotificationChannels {
    /** The fallback category of data messages that name none. */
    public const val GENERAL_CATEGORY: String = "general"

    public fun channelId(
        category: String,
        level: RelayInterruptionLevel,
    ): String = "relay.$category.${level.wire}"

    /** The highest level a class may use without a critical grant. */
    public fun ceiling(messageClass: RelayMessageClass): RelayInterruptionLevel? =
        when (messageClass) {
            RelayMessageClass.SECURITY, RelayMessageClass.ACTION_REQUIRED -> RelayInterruptionLevel.TIME_SENSITIVE
            RelayMessageClass.TRANSACTIONAL, RelayMessageClass.OPERATIONAL, RelayMessageClass.SOCIAL -> RelayInterruptionLevel.ACTIVE
            RelayMessageClass.MARKETING -> RelayInterruptionLevel.PASSIVE
            RelayMessageClass.SYSTEM -> null
        }

    /** The class default importance of the channel table. */
    public fun classImportance(messageClass: RelayMessageClass): Int =
        when (messageClass) {
            RelayMessageClass.SECURITY, RelayMessageClass.ACTION_REQUIRED -> NotificationManager.IMPORTANCE_HIGH
            RelayMessageClass.TRANSACTIONAL, RelayMessageClass.OPERATIONAL -> NotificationManager.IMPORTANCE_DEFAULT
            RelayMessageClass.SOCIAL, RelayMessageClass.MARKETING -> NotificationManager.IMPORTANCE_LOW
            RelayMessageClass.SYSTEM -> NotificationManager.IMPORTANCE_NONE
        }

    /** The importance of a level, never above the class default except for `critical`. */
    public fun importance(
        messageClass: RelayMessageClass,
        level: RelayInterruptionLevel,
    ): Int {
        val levelImportance =
            when (level) {
                RelayInterruptionLevel.PASSIVE -> NotificationManager.IMPORTANCE_LOW
                RelayInterruptionLevel.ACTIVE -> NotificationManager.IMPORTANCE_DEFAULT
                RelayInterruptionLevel.TIME_SENSITIVE, RelayInterruptionLevel.CRITICAL -> NotificationManager.IMPORTANCE_HIGH
            }
        if (level == RelayInterruptionLevel.CRITICAL) return levelImportance
        return minOf(levelImportance, classImportance(messageClass))
    }

    /** The channels of one category: every level up to the class ceiling, and `critical` when the app opted in. */
    public fun specs(
        category: RelayCategoryInfo,
        critical: Boolean = false,
    ): List<RelayChannelSpec> {
        val ceiling = ceiling(category.messageClass) ?: return emptyList()
        val levels = RelayInterruptionLevel.entries.filter { it.ordinal <= ceiling.ordinal }.toMutableList()
        if (critical) levels += RelayInterruptionLevel.CRITICAL
        return levels.map { level ->
            RelayChannelSpec(channelId(category.key, level), category.key, level, importance(category.messageClass, level))
        }
    }

    /**
     * Creates the channels on first launch. An existing channel keeps the importance the user chose;
     * only its name is refreshed.
     */
    public fun create(
        context: Context,
        categories: List<RelayCategoryInfo>,
        levelNames: (RelayInterruptionLevel) -> String,
        critical: Boolean = false,
    ) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val all = categories + RelayCategoryInfo(GENERAL_CATEGORY, GENERAL_CATEGORY, RelayMessageClass.TRANSACTIONAL)
        for (category in all) {
            manager.createNotificationChannelGroup(NotificationChannelGroup("relay.${category.key}", category.name))
            for (spec in specs(category, critical && category.key != GENERAL_CATEGORY)) {
                val channel = NotificationChannel(spec.id, "${category.name} · ${levelNames(spec.level)}", spec.importance)
                channel.group = "relay.${category.key}"
                if (spec.level == RelayInterruptionLevel.CRITICAL) channel.setBypassDnd(true)
                manager.createNotificationChannel(channel)
            }
        }
    }

    // CH-28

    /** The Relay channels as the device holds them now, with the importance the user left them at. */
    public fun reported(context: Context): List<Pair<String, String>> {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return emptyList()
        return manager.notificationChannels
            .filter { it.id.startsWith("relay.") }
            .take(50)
            .map { it.id to importanceName(it.importance) }
    }

    /** The contract's name of an Android importance. */
    public fun importanceName(importance: Int): String =
        when (importance) {
            NotificationManager.IMPORTANCE_NONE -> "none"
            NotificationManager.IMPORTANCE_MIN -> "min"
            NotificationManager.IMPORTANCE_LOW -> "low"
            NotificationManager.IMPORTANCE_HIGH, NotificationManager.IMPORTANCE_MAX -> "high"
            else -> "default"
        }
}

/** The operating system notification permission as Relay records it (CH-28). */
public enum class RelayPermission(
    public val wire: String,
) {
    GRANTED("granted"),
    DENIED("denied"),
    PROVISIONAL("provisional"),
    NOT_DETERMINED("not_determined"),
}

/** What the device allows: the permission and whether `critical` channels may break through DND (CH-65). */
public data class RelayNotificationSettings(
    val permission: RelayPermission,
    val dndAccessGranted: Boolean = false,
)

/** Reads the device's notification settings; tests replace it. */
public fun interface RelayNotificationSettingsReader {
    public fun read(): RelayNotificationSettings
}

// CH-28
// CH-65

/** Reads the permission (Android 13 runtime permission or the app switch) and the DND access status. */
public class SystemNotificationSettingsReader(
    private val context: Context,
) : RelayNotificationSettingsReader {
    override fun read(): RelayNotificationSettings {
        val manager = context.getSystemService(NotificationManager::class.java)
        val enabled = manager?.areNotificationsEnabled() ?: false
        val permission =
            when {
                enabled -> RelayPermission.GRANTED
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                    context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
                    !wasRequested(context) -> RelayPermission.NOT_DETERMINED
                else -> RelayPermission.DENIED
            }
        return RelayNotificationSettings(permission, manager?.isNotificationPolicyAccessGranted ?: false)
    }

    public companion object {
        private const val PREFERENCES = "app.suiss.relay.permission"

        /** Call when the app has shown the system permission prompt, so a refusal reads as `denied`. */
        public fun markRequested(context: Context) {
            context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit().putBoolean("requested", true).apply()
        }

        private fun wasRequested(context: Context): Boolean =
            context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).getBoolean("requested", false)
    }
}
