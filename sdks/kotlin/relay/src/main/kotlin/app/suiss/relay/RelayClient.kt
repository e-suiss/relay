package app.suiss.relay

import android.content.Context
import android.content.Intent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import okhttp3.OkHttpClient

// X-31

/**
 * The Relay subscriber client of an Android app: inbox, preferences, push devices and realtime with the
 * mobile lifecycle. It only acts for the subscriber of its token and never triggers events.
 */
public class RelayClient internal constructor(
    public val configuration: RelayConfiguration,
    context: Context,
    okHttp: OkHttpClient,
    deviceStorage: RelayDeviceStorage,
    queueStorage: IntentQueueStorage,
    settings: RelayNotificationSettingsReader,
    realtimeTransports: List<RelayRealtimeTransport>?,
    public val scope: CoroutineScope,
    smallIcon: Int,
    launchIntent: () -> Intent?,
) : RelayLifecycleSteps {
    internal val http: RelayHttp = RelayHttp(configuration, okHttp)
    public val inbox: RelayInboxApi = RelayInboxApi(http)
    public val push: RelayPushApi =
        RelayPushApi(http, deviceStorage, settings) { RelayNotificationChannels.reported(context.applicationContext) }
    public val preferences: RelayPreferencesApi = RelayPreferencesApi(http)
    public val store: RelayInboxStore = RelayInboxStore(inbox, IntentQueue(queueStorage, configuration.random), configuration.clock, scope)
    public val remover: RelayNotificationRemover = RelayNotificationRemover(context.applicationContext)
    public val realtime: RelayRealtimeConnection =
        RelayRealtimeConnection(
            transports =
                realtimeTransports ?: listOf(
                    WebSocketRealtimeTransport(http) { deviceStorage.load()?.deviceId },
                    ServerSentEventsRealtimeTransport(http) { deviceStorage.load()?.deviceId },
                    LongPollRealtimeTransport(http),
                ),
            tokens = http.tokens,
            clock = configuration.clock,
            random = configuration.random,
            scope = scope,
        )
    public val lifecycle: RelayLifecycle = RelayLifecycle(this)
    public val displayed: RelayDisplayedNotifications = RelayDisplayedNotifications.over(http, CoroutineDisplayedScheduler(scope))
    public val messaging: RelayDataMessageHandler =
        RelayDataMessageHandler(context.applicationContext, push, { onSyncSignal() }, smallIcon, launchIntent, displayed)

    public constructor(
        configuration: RelayConfiguration,
        context: Context,
        smallIcon: Int,
        launchIntent: () -> Intent? = { context.packageManager.getLaunchIntentForPackage(context.packageName) },
    ) : this(
        configuration = configuration,
        context = context,
        okHttp = OkHttpClient(),
        deviceStorage = SharedPreferencesDeviceStorage(context),
        queueStorage = SharedPreferencesIntentQueueStorage(context),
        settings = SystemNotificationSettingsReader(context),
        realtimeTransports = null,
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
        smallIcon = smallIcon,
        launchIntent = launchIntent,
    )

    init {
        store.onItemsRemoved = { items -> remover.remove(items) }
        realtime.onEnvelope = { envelope -> store.handle(envelope) }
        store.onItemDisplayed = { item -> displayed.report(item.id) }
    }

    // CH-32

    /** Records the click of a Relay notification (the extras of its launch intent) and marks its item read. */
    public suspend fun handleNotificationOpened(extras: Map<String, String>) {
        val payload = RelayPushPayload.from(extras) ?: return
        payload.deliveryId?.let { runCatching { push.record(RelayReceipt.CLICKED, it) } }
        val itemId = payload.itemId ?: return
        store.items.value.firstOrNull { it.id == itemId }?.let { store.perform(RelayInboxOperation.CLICK, it) }
    }

    private suspend fun onSyncSignal() {
        store.refreshCounters()
        store.synchronize()
        if (store.counters.value.unread == 0) remover.removeAll()
    }

    override suspend fun refreshCounters(): Unit = store.refreshCounters()

    override suspend fun connectRealtime(): Unit = realtime.connect(store.streamCursor)

    override suspend fun synchronize(): Unit = store.synchronize()

    override suspend fun drainQueue(): Unit = store.drainQueue()

    override suspend fun disconnectRealtime(): Unit = realtime.disconnect()

    override suspend fun flushDisplayedNotifications(): Unit = displayed.flush()
}
