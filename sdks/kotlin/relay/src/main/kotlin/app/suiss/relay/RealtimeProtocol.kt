package app.suiss.relay

import com.google.gson.JsonArray
import com.google.gson.JsonNull
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.google.gson.JsonPrimitive
import java.util.Base64

/** The absolute inbox counters; a client keeps only counters newer than its own (IN-18, IN-19). */
public data class RelayInboxCounters(
    val unseen: Int,
    val unread: Int,
    val total: Int,
    val version: Int,
) {
    public companion object {
        public val ZERO: RelayInboxCounters = RelayInboxCounters(0, 0, 0, -1)
    }
}

/** A partial state change of an inbox item. */
public data class RelayItemPatch(
    val id: String,
    val stateVersion: Int,
    val seen: Boolean? = null,
    val read: Boolean? = null,
    val archived: Boolean? = null,
    val hidden: Boolean? = null,
    val expired: Boolean? = null,
)

/** One realtime envelope `{t, v, ts, id, d, counters}` (IN-26). */
public class RelayRealtimeEnvelope(
    public val type: String,
    public val id: String?,
    public val payload: JsonObject,
    public val counters: RelayInboxCounters,
) {
    /** The state change of `inbox.item_updated`: only the fields the server sent. */
    public val itemPatch: RelayItemPatch?
        get() {
            if (type != "inbox.item_updated") return null
            val id = payload.string("item_id") ?: return null
            val version = payload.get("state_version")?.takeIf { it.isJsonPrimitive }?.asInt ?: return null
            val changes = payload.get("changes")?.takeIf { it.isJsonObject }?.asJsonObject ?: JsonObject()

            fun flag(name: String): Boolean? = changes.get(name)?.takeIf { it.isJsonPrimitive }?.asBoolean
            return RelayItemPatch(id, version, flag("seen"), flag("read"), flag("archived"), flag("hidden"), flag("expired"))
        }

    /** The item JSON of `inbox.item_created` and whether it is thin (IN-27, IN-49). */
    public val createdItem: Pair<JsonObject, Boolean>?
        get() {
            if (type != "inbox.item_created") return null
            val item = payload.get("item")?.takeIf { it.isJsonObject }?.asJsonObject ?: return null
            return item to (payload.get("thin")?.takeIf { it.isJsonPrimitive }?.asBoolean ?: false)
        }

    public companion object {
        public fun parse(json: String): RelayRealtimeEnvelope? = runCatching { from(JsonParser.parseString(json).asJsonObject) }.getOrNull()

        public fun from(json: JsonObject): RelayRealtimeEnvelope? {
            val type = json.string("t") ?: return null
            val counters = json.get("counters")?.takeIf { it.isJsonObject }?.asJsonObject ?: return null
            return RelayRealtimeEnvelope(
                type = type,
                id = json.string("id"),
                payload = json.get("d")?.takeIf { it.isJsonObject }?.asJsonObject ?: JsonObject(),
                counters =
                    RelayInboxCounters(
                        unseen = counters.get("unseen").asInt,
                        unread = counters.get("unread").asInt,
                        total = counters.get("total").asInt,
                        version = counters.get("version").asInt,
                    ),
            )
        }
    }
}

/** One Server-Sent Event. */
public data class ServerSentEvent(
    val event: String?,
    val data: String,
    val id: String?,
)

// IN-23

/** Incremental `text/event-stream` parser: feed it lines without their terminators. */
public class ServerSentEventParser {
    private var event: String? = null
    private val data = mutableListOf<String>()
    private var id: String? = null

    public fun feed(line: String): ServerSentEvent? {
        if (line.isEmpty()) {
            val result = if (data.isEmpty()) null else ServerSentEvent(event, data.joinToString("\n"), id)
            event = null
            data.clear()
            return result
        }
        if (line.startsWith(":")) return null
        val colon = line.indexOf(':')
        val field = if (colon < 0) line else line.substring(0, colon)
        val value = if (colon < 0) "" else line.substring(colon + 1).removePrefix(" ")
        when (field) {
            "event" -> event = value
            "data" -> data.add(value)
            "id" -> id = value
        }
        return null
    }
}

// IN-23

/** The Phoenix Channels v2 JSON frame `[join_ref, ref, topic, event, payload]`. */
public data class PhoenixFrame(
    val joinRef: String?,
    val ref: String?,
    val topic: String,
    val event: String,
    val payload: JsonObject,
) {
    public fun encoded(): String {
        val array = JsonArray()
        array.add(joinRef?.let(::JsonPrimitive) ?: JsonNull.INSTANCE)
        array.add(ref?.let(::JsonPrimitive) ?: JsonNull.INSTANCE)
        array.add(topic)
        array.add(event)
        array.add(payload)
        return array.toString()
    }

    public companion object {
        public fun decode(text: String): PhoenixFrame? =
            runCatching {
                val array = JsonParser.parseString(text).asJsonArray
                if (array.size() != 5) return@runCatching null
                PhoenixFrame(
                    joinRef = array[0].takeUnless { it.isJsonNull }?.asString,
                    ref = array[1].takeUnless { it.isJsonNull }?.asString,
                    topic = array[2].asString,
                    event = array[3].asString,
                    payload = array[4].takeIf { it.isJsonObject }?.asJsonObject ?: JsonObject(),
                )
            }.getOrNull()

        /** The WebSocket subprotocols that carry the subscriber token as the channels `authToken`. */
        public fun subprotocols(token: String): String {
            val encoded = Base64.getUrlEncoder().withoutPadding().encodeToString(token.toByteArray(Charsets.UTF_8))
            return "phoenix, base64url.bearer.phx.$encoded"
        }
    }
}
