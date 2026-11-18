package app.suiss.relay

import kotlinx.coroutines.delay
import java.util.UUID
import kotlin.math.min
import kotlin.math.pow

/** Time source of the SDK; tests replace it to control backoff and expiry without waiting. */
public interface RelayClock {
    public fun nowMillis(): Long

    public suspend fun sleep(millis: Long)
}

/** Randomness of the SDK (jitter and idempotency keys); tests replace it with a fixed sequence. */
public interface RelayRandom {
    public fun unit(): Double

    public fun uuid(): UUID
}

/** Receives diagnostic messages. Messages never carry tokens, push tokens or device status values. */
public fun interface RelayLogger {
    public fun log(
        level: Level,
        message: String,
    )

    /** Severity of a diagnostic message. */
    public enum class Level { DEBUG, INFO, WARNING, ERROR }
}

/** The wall clock and coroutine `delay`. */
public object SystemClock : RelayClock {
    override fun nowMillis(): Long = System.currentTimeMillis()

    override suspend fun sleep(millis: Long) {
        if (millis > 0) delay(millis)
    }
}

/** The platform random number generator. */
public object SystemRandom : RelayRandom {
    override fun unit(): Double = Math.random()

    override fun uuid(): UUID = UUID.randomUUID()
}

// IN-34
// IN-52

/** Exponential backoff with full jitter: attempt n waits a uniform time in [0, min(cap, base * 2^n)]. */
public class FullJitterBackoff(
    public val baseMillis: Long = 1_000,
    public val capMillis: Long = 60_000,
) {
    /** The upper bound of the wait before attempt [attempt] (0 based). */
    public fun ceiling(attempt: Int): Long {
        val exponent = attempt.coerceIn(0, 30)
        return min(capMillis.toDouble(), baseMillis * 2.0.pow(exponent)).toLong()
    }

    /** The wait before attempt [attempt]; a server `Retry-After` is a floor the wait never goes below. */
    public fun delay(
        attempt: Int,
        random: RelayRandom,
        retryAfterMillis: Long? = null,
    ): Long {
        val jittered = (random.unit() * ceiling(attempt)).toLong()
        return if (retryAfterMillis != null && retryAfterMillis > 0) maxOf(retryAfterMillis, jittered) else jittered
    }
}

/** Idempotency keys: random, never derived from content and free of personal data. */
internal object IdempotencyKey {
    fun make(random: RelayRandom): String = "rly-" + random.uuid().toString().lowercase()
}
