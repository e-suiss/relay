package app.suiss.relay

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

// X-31

/**
 * A narrow-scope Relay subscriber token. The host app obtains it (the Access token exchange runs on
 * its side) and hands it to the SDK; the SDK never holds Access tokens, API keys or other secrets.
 */
public class RelaySubscriberToken(
    public val value: String,
    public val expiresAtMillis: Long,
    public val scopes: Set<RelayScope> = emptySet(),
) {
    internal fun allows(scope: RelayScope): Boolean = scopes.isEmpty() || scope in scopes

    override fun toString(): String = "RelaySubscriberToken(redacted)"
}

/** The subscriber token scopes of the subscriber API. */
public enum class RelayScope(
    public val wire: String,
) {
    INBOX_READ("inbox:read"),
    INBOX_WRITE("inbox:write"),
    PREFERENCES("preferences"),
    DEVICES_WRITE("devices:write"),
    PRESENCE_WRITE("presence:write"),
    AGUI_READ("agui:read"),
}

// X-31

/** Supplies subscriber tokens; [forceRefresh] asks for a new token after Relay refused the current one. */
public fun interface RelayTokenProvider {
    public suspend fun subscriberToken(forceRefresh: Boolean): RelaySubscriberToken
}

/** Settings of a Relay client. */
public class RelayConfiguration(
    public val baseUrl: String,
    public val appIdentifier: String,
    public val tokenProvider: RelayTokenProvider,
    public val clock: RelayClock = SystemClock,
    public val random: RelayRandom = SystemRandom,
    public val logger: RelayLogger = RelayLogger { _, _ -> },
    public val maxRetries: Int = 3,
) {
    public companion object {
        /** The dated API version this SDK release is pinned to (X-48). */
        public const val API_VERSION: String = RelayVersion.API
    }
}

/** Caches the current subscriber token and refreshes it shortly before expiry. */
internal class TokenStore(
    private val provider: RelayTokenProvider,
    private val clock: RelayClock,
) {
    private val mutex = Mutex()
    private var current: RelaySubscriberToken? = null

    suspend fun token(): RelaySubscriberToken =
        mutex.withLock {
            val cached = current
            if (cached != null && cached.expiresAtMillis - clock.nowMillis() > 30_000) {
                cached
            } else {
                val fresh = provider.subscriberToken(forceRefresh = cached != null)
                current = fresh
                fresh
            }
        }

    suspend fun refresh(): RelaySubscriberToken =
        mutex.withLock {
            val fresh = provider.subscriberToken(forceRefresh = true)
            current = fresh
            fresh
        }
}
