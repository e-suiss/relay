package app.suiss.relay

import app.suiss.relay.api.model.Channel
import app.suiss.relay.api.model.MyPreferencesPatch
import app.suiss.relay.api.model.PreferenceLevel
import app.suiss.relay.api.model.PreferenceValue
import app.suiss.relay.api.model.PreferenceWrite
import app.suiss.relay.api.model.SubscriberPreferences
import com.google.gson.JsonObject

/** A stored preference value; `unset` falls back to the next level. */
public enum class RelayPreferenceValue(
    public val wire: String,
) {
    OPT_IN("opt_in"),
    OPT_OUT("opt_out"),
    UNSET("unset"),
}

/** Where the effective value of a cell comes from (PC-12, PC-15). */
public enum class RelayPreferenceSource(
    public val wire: String,
) {
    USER("user"),
    TENANT("tenant"),
    CATEGORY_DEFAULT("category_default"),
    CLASS_DEFAULT("class_default"),
    LOCKED("locked"),
}

/** The digest choice of a category (PC-17). */
public enum class RelayDigestChoice(
    public val wire: String,
) {
    INSTANT("instant"),
    DIGEST("digest"),
}

/** One category × channel cell. */
public data class RelayPreferenceCell(
    val category: String,
    val channel: String,
    val value: RelayPreferenceValue,
    val effective: Boolean,
    val source: RelayPreferenceSource,
)

/** The subscriber's preferences as the components show them. */
public data class RelayPreferences(
    val cells: List<RelayPreferenceCell>,
    val channels: Map<String, RelayPreferenceValue> = emptyMap(),
    val digest: Map<String, RelayDigestChoice> = emptyMap(),
) {
    /** The categories in the order the server listed them. */
    val categories: List<String> get() = cells.map { it.category }.distinct()

    public fun cells(category: String): List<RelayPreferenceCell> = cells.filter { it.category == category }

    internal companion object {
        fun from(preferences: SubscriberPreferences): RelayPreferences {
            val digest = mutableMapOf<String, RelayDigestChoice>()
            val choices: JsonObject? = preferences.profile.digest
            choices?.entrySet()?.forEach { (key, value) ->
                RelayDigestChoice.entries.firstOrNull { it.wire == value.asString }?.let { digest[key] = it }
            }
            return RelayPreferences(
                cells =
                    preferences.cells.map { cell ->
                        RelayPreferenceCell(
                            category = cell.category,
                            channel = cell.channel.value,
                            value = RelayPreferenceValue.entries.firstOrNull { it.wire == cell.`value`.value } ?: RelayPreferenceValue.UNSET,
                            effective = cell.effective,
                            source =
                                RelayPreferenceSource.entries.firstOrNull { it.wire == cell.source.value }
                                    ?: RelayPreferenceSource.CLASS_DEFAULT,
                        )
                    },
                channels =
                    preferences.channels.associate { channel ->
                        channel.channel.value to
                            (RelayPreferenceValue.entries.firstOrNull { it.wire == channel.`value`.value } ?: RelayPreferenceValue.UNSET)
                    },
                digest = digest,
            )
        }
    }
}

// X-31

/**
 * The subscriber's own preferences (scope `preferences`): category × channel and channel switches and
 * the digest choice. Identity, contact data and consents are never written from the device.
 */
public class RelayPreferencesApi internal constructor(
    private val http: RelayHttp,
) {
    public suspend fun load(): RelayPreferences =
        RelayPreferences.from(
            http.decode<SubscriberPreferences>(http.send(RelayScope.PREFERENCES, "GET", http.url("v1/subscriber/preferences"))),
        )

    public suspend fun set(
        category: String,
        channel: String,
        value: RelayPreferenceValue,
    ): RelayPreferences =
        patch(
            MyPreferencesPatch(
                preferences =
                    listOf(
                        PreferenceWrite(
                            level = PreferenceLevel.entries.first { it.value == "category_channel" },
                            `value` = wire(value),
                            category = category,
                            channel = channel(channel),
                        ),
                    ),
            ),
        )

    public suspend fun setChannel(
        channel: String,
        value: RelayPreferenceValue,
    ): RelayPreferences =
        patch(
            MyPreferencesPatch(
                preferences =
                    listOf(
                        PreferenceWrite(
                            level = PreferenceLevel.entries.first { it.value == "channel" },
                            `value` = wire(value),
                            channel = channel(channel),
                        ),
                    ),
            ),
        )

    // PC-17

    /** Sets the digest choice of one category; the digest map is written as a whole. */
    public suspend fun setDigest(
        category: String,
        choice: RelayDigestChoice,
        current: RelayPreferences,
    ): RelayPreferences {
        val digest = JsonObject()
        current.digest.forEach { (key, value) -> digest.addProperty(key, value.wire) }
        digest.addProperty(category, choice.wire)
        val profile = JsonObject().apply { add("digest", digest) }
        val body = JsonObject().apply { add("profile", profile) }
        return patch(body)
    }

    private suspend fun patch(body: Any): RelayPreferences {
        val key = IdempotencyKey.make(http.configuration.random)
        val answer = http.send(RelayScope.PREFERENCES, "PATCH", http.url("v1/subscriber/preferences"), body, key)
        return RelayPreferences.from(http.decode<SubscriberPreferences>(answer))
    }

    private fun wire(value: RelayPreferenceValue): PreferenceValue = PreferenceValue.entries.first { it.value == value.wire }

    private fun channel(name: String): Channel =
        Channel.entries.firstOrNull { it.value == name } ?: throw RelayException.InvalidResponse("unknown channel $name")
}
