package app.suiss.relay.docs

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import app.suiss.relay.RelayClient
import app.suiss.relay.RelayConfiguration
import app.suiss.relay.RelaySubscriberToken
import app.suiss.relay.ui.RelayInbox
import app.suiss.relay.ui.RelayTheme
import app.suiss.relay.ui.RelayThemeProvider

internal fun interface Backend {
    suspend fun relaySubscriberToken(refresh: Boolean): RelaySubscriberToken
}

internal fun createClient(
    context: Context,
    backend: Backend,
    smallIcon: Int,
): RelayClient {
    // #region client
    val client =
        RelayClient(
            configuration =
                RelayConfiguration(
                    baseUrl = "https://relay.example.com",
                    appIdentifier = context.packageName,
                    tokenProvider = { refresh -> backend.relaySubscriberToken(refresh) },
                ),
            context = context,
            smallIcon = smallIcon,
        )
    client.lifecycle.observeProcess(client.scope)
    // #endregion client
    return client
}

// #region push
internal suspend fun onNewToken(
    client: RelayClient,
    token: String,
) {
    client.push.register(token)
}

internal suspend fun onMessageReceived(
    client: RelayClient,
    data: Map<String, String>,
) {
    client.messaging.handle(data)
}
// #endregion push

// #region inbox
@Composable
internal fun InboxScreen(client: RelayClient) {
    RelayThemeProvider(RelayTheme(accent = Color(0xFF2457C5))) {
        RelayInbox(client.store)
    }
}
// #endregion inbox
