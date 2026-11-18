package app.suiss.relay

import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** The steps the lifecycle runs; `RelayClient` implements them and tests record their order. */
public interface RelayLifecycleSteps {
    public suspend fun refreshCounters()

    public suspend fun connectRealtime()

    public suspend fun synchronize()

    public suspend fun drainQueue()

    public suspend fun disconnectRealtime()
}

// IN-35

/**
 * The mobile lifecycle: the background closes the realtime connection; the foreground asks for the
 * counters (the badge is right at once), connects, runs a delta or cold sync, and drains the offline
 * queue last so it causes no needless `409`.
 */
public class RelayLifecycle(
    private val steps: RelayLifecycleSteps,
) {
    private val mutex = Mutex()
    private var inForeground = false

    public suspend fun enterForeground() {
        mutex.withLock {
            if (inForeground) return
            inForeground = true
            steps.refreshCounters()
            steps.connectRealtime()
            steps.synchronize()
            steps.drainQueue()
        }
    }

    public suspend fun enterBackground() {
        mutex.withLock {
            if (!inForeground) return
            inForeground = false
            steps.disconnectRealtime()
        }
    }

    /** Follows the app process: foreground on start, background on stop. */
    public fun observeProcess(scope: CoroutineScope) {
        ProcessLifecycleOwner.get().lifecycle.addObserver(
            object : DefaultLifecycleObserver {
                override fun onStart(owner: LifecycleOwner) {
                    scope.launch { enterForeground() }
                }

                override fun onStop(owner: LifecycleOwner) {
                    scope.launch { enterBackground() }
                }
            },
        )
    }
}
