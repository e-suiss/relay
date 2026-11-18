package app.suiss.relay

import com.google.gson.Gson
import com.google.gson.GsonBuilder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.CancellationException

/** One HTTP answer: the status and the body text. */
internal class HttpAnswer(
    val status: Int,
    val body: String,
)

/**
 * Calls the subscriber API with the retry rules of the SDK: only retryable errors are repeated, with
 * full jitter backoff and `Retry-After` as a floor, and a mutation keeps its idempotency key.
 */
internal class RelayHttp(
    val configuration: RelayConfiguration,
    val client: OkHttpClient = OkHttpClient(),
) {
    val tokens = TokenStore(configuration.tokenProvider, configuration.clock)
    val gson: Gson = GsonBuilder().disableHtmlEscaping().create()
    private val backoff = FullJitterBackoff(baseMillis = 500, capMillis = 30_000)
    private val base: HttpUrl = configuration.baseUrl.toHttpUrl()

    fun url(
        path: String,
        query: Map<String, String?> = emptyMap(),
    ): HttpUrl {
        val builder = base.newBuilder()
        path.trim('/').split('/').forEach { builder.addPathSegment(it) }
        query.forEach { (name, value) -> if (value != null) builder.addQueryParameter(name, value) }
        return builder.build()
    }

    // X-29
    suspend fun send(
        scope: RelayScope,
        method: String,
        url: HttpUrl,
        body: Any? = null,
        idempotencyKey: String? = null,
    ): HttpAnswer {
        val first = tokens.token()
        if (!first.allows(scope)) throw RelayException.MissingScope(scope)
        var attempt = 0
        var refreshed = false
        while (true) {
            try {
                return once(method, url, body, idempotencyKey)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: RelayException) {
                val expired = (error as? RelayException.Problem)?.problem?.let(::isExpiredToken) ?: false
                if (expired && !refreshed) {
                    refreshed = true
                    tokens.refresh()
                    continue
                }
                if (!error.isRetryable || attempt >= configuration.maxRetries) throw error
                val wait = backoff.delay(attempt, configuration.random, error.retryAfter?.times(1_000))
                attempt += 1
                configuration.logger.log(RelayLogger.Level.DEBUG, "retrying after a retryable error")
                configuration.clock.sleep(wait)
            }
        }
    }

    inline fun <reified T> decode(answer: HttpAnswer): T =
        runCatching { gson.fromJson(answer.body, T::class.java) }.getOrNull()
            ?: throw RelayException.InvalidResponse("unreadable ${T::class.java.simpleName}")

    private suspend fun once(
        method: String,
        url: HttpUrl,
        body: Any?,
        idempotencyKey: String?,
    ): HttpAnswer {
        val token = tokens.token()
        val requestBody = body?.let { gson.toJson(it).toRequestBody(JSON) }
        val request =
            Request
                .Builder()
                .url(url)
                .method(method, requestBody ?: if (method == "POST" || method == "PATCH") "".toRequestBody(JSON) else null)
                .header("Authorization", "Bearer ${token.value}")
                .header("Relay-Version", RelayConfiguration.API_VERSION)
                .header("Accept", "application/json")
                .apply { if (idempotencyKey != null) header("Idempotency-Key", idempotencyKey) }
                .build()
        return withContext(Dispatchers.IO) {
            val response =
                try {
                    client.newCall(request).execute()
                } catch (error: IOException) {
                    throw RelayException.Transport("network error ${error.javaClass.simpleName}")
                }
            response.use {
                val text = it.body.string()
                if (it.code >= 400) {
                    val problem =
                        RelayProblem.parse(text)
                            ?: RelayProblem(type = "about:blank", title = "HTTP ${it.code}", status = it.code, code = "http_${it.code}")
                    throw RelayException.Problem(problem, it.header("Retry-After")?.trim()?.toLongOrNull())
                }
                HttpAnswer(it.code, text)
            }
        }
    }

    private fun isExpiredToken(problem: RelayProblem): Boolean =
        problem.status == 401 && (problem.code == "auth_expired_token" || problem.code == "auth_invalid_token")

    companion object {
        val JSON = "application/json".toMediaType()
    }
}
