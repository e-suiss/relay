package app.suiss.relay

import com.google.gson.JsonObject
import com.google.gson.JsonParser

/** RFC 9457 problem details returned by Relay. */
public data class RelayProblem(
    val type: String,
    val title: String,
    val status: Int,
    val code: String,
    val detail: String? = null,
    val retryable: Boolean? = null,
    val retryAfter: Int? = null,
    val current: RelayItemState? = null,
) {
    internal companion object {
        fun parse(body: String): RelayProblem? =
            runCatching {
                val json = JsonParser.parseString(body).asJsonObject
                RelayProblem(
                    type = json.get("type").asString,
                    title = json.get("title").asString,
                    status = json.get("status").asInt,
                    code = json.get("code").asString,
                    detail = json.string("detail"),
                    retryable = json.get("retryable")?.takeIf { it.isJsonPrimitive }?.asBoolean,
                    retryAfter = json.get("retry_after")?.takeIf { it.isJsonPrimitive }?.asInt,
                    current = json.get("current")?.takeIf { it.isJsonObject }?.asJsonObject?.let(RelayItemState::fromJson),
                )
            }.getOrNull()
    }
}

/** Errors thrown by the SDK. */
public sealed class RelayException(
    message: String,
) : Exception(message) {
    /** A problem response. */
    public class Problem(
        public val problem: RelayProblem,
        public val retryAfterSeconds: Long?,
    ) : RelayException(problem.code)

    /** The request did not reach Relay or its answer was lost. */
    public class Transport(
        message: String,
    ) : RelayException(message)

    /** The subscriber token lacks the scope the operation needs. */
    public class MissingScope(
        public val scope: RelayScope,
    ) : RelayException("missing scope ${scope.wire}")

    /** Relay answered with something the SDK cannot read. */
    public class InvalidResponse(
        message: String,
    ) : RelayException(message)

    /** The device has no push registration yet. */
    public class NotRegistered : RelayException("device not registered")

    /** Whether repeating the same request, with the same idempotency key, can succeed. */
    public val isRetryable: Boolean
        get() =
            when (this) {
                is Problem -> RetryClassifier.isRetryable(problem.status, problem.code, problem.retryable)
                is Transport -> true
                else -> false
            }

    /** The server's `Retry-After`, in seconds, when it sent one. */
    public val retryAfter: Long?
        get() = (this as? Problem)?.let { it.retryAfterSeconds ?: it.problem.retryAfter?.toLong() }

    /** The problem code, when the error is a problem response. */
    public val code: String?
        get() = (this as? Problem)?.problem?.code
}

// X-29

/**
 * The retryable mapping of the error catalog: the problem's own `retryable` member wins, and the
 * status defaults of the catalog apply when the body carries none.
 */
public object RetryClassifier {
    public fun isRetryable(
        status: Int,
        code: String?,
        declared: Boolean?,
    ): Boolean = declared ?: defaultRetryable(status, code)

    public fun defaultRetryable(
        status: Int,
        code: String?,
    ): Boolean =
        when (status) {
            409 -> code == "idempotency_key_in_progress"
            429 -> code != "quota_exhausted"
            500, 503, 504 -> true
            else -> false
        }
}

/** The state of an inbox item without its content. */
public data class RelayItemState(
    val id: String,
    val stateVersion: Int,
    val seen: Boolean,
    val read: Boolean,
    val archived: Boolean,
    val hidden: Boolean,
    val expired: Boolean,
) {
    internal companion object {
        fun fromJson(json: JsonObject): RelayItemState =
            RelayItemState(
                id = json.get("id").asString,
                stateVersion = json.get("state_version").asInt,
                seen = json.bool("seen"),
                read = json.bool("read"),
                archived = json.bool("archived"),
                hidden = json.bool("hidden"),
                expired = json.bool("expired"),
            )
    }
}

internal fun JsonObject.string(name: String): String? = get(name)?.takeIf { it.isJsonPrimitive }?.asString

internal fun JsonObject.bool(name: String): Boolean = get(name)?.takeIf { it.isJsonPrimitive }?.asBoolean ?: false
