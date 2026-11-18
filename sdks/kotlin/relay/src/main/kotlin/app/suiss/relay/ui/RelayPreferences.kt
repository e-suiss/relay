package app.suiss.relay.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.suiss.relay.R
import app.suiss.relay.RelayCategoryInfo
import app.suiss.relay.RelayDigestChoice
import app.suiss.relay.RelayException
import app.suiss.relay.RelayLockBeneficiary
import app.suiss.relay.RelayNotificationSettingsReader
import app.suiss.relay.RelayPermission
import app.suiss.relay.RelayPreferenceCell
import app.suiss.relay.RelayPreferenceValue
import app.suiss.relay.RelayPreferences
import app.suiss.relay.RelayPreferencesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

// PC-15
// PC-16
// X-51

/** How one cell is shown. */
public enum class RelayPreferenceRowState {
    ON,
    OFF,
    LOCKED_ON,
    ADMIN_DISABLED,
    DEVICE_DISABLED,
    PERMISSION_PENDING,
    ;

    /** Whether the user can change the cell from the component. */
    public val isEditable: Boolean get() = this == ON || this == OFF

    public companion object {
        public fun of(
            cell: RelayPreferenceCell,
            permission: RelayPermission,
        ): RelayPreferenceRowState {
            if (cell.locked) return LOCKED_ON
            if (cell.disabledByAdmin) return ADMIN_DISABLED
            if (cell.disabledInDeviceSettings) return DEVICE_DISABLED
            if (cell.channel == "push") {
                when (permission) {
                    RelayPermission.DENIED -> return DEVICE_DISABLED
                    RelayPermission.NOT_DETERMINED -> return PERMISSION_PENDING
                    RelayPermission.GRANTED, RelayPermission.PROVISIONAL -> Unit
                }
            }
            return if (cell.effective) ON else OFF
        }
    }
}

// PC-17

/** The three choices shown when the user turns a digest category off; none is preselected. */
public enum class RelayTurnOffChoice { INSTANT, DIGEST, NEVER }

/** The preference centre state behind [RelayPreferencesScreen]. */
public class RelayPreferencesModel(
    private val api: RelayPreferencesApi,
    categories: List<RelayCategoryInfo> = emptyList(),
    private val settings: RelayNotificationSettingsReader,
) {
    private val byKey = categories.associateBy { it.key }
    private val mutablePreferences = MutableStateFlow<RelayPreferences?>(null)
    private val mutablePermission = MutableStateFlow(RelayPermission.NOT_DETERMINED)
    private val mutablePending = MutableStateFlow<RelayPreferenceCell?>(null)
    private val mutableError = MutableStateFlow<RelayException?>(null)

    public val preferences: StateFlow<RelayPreferences?> = mutablePreferences
    public val permission: StateFlow<RelayPermission> = mutablePermission
    public val pendingTurnOff: StateFlow<RelayPreferenceCell?> = mutablePending
    public val lastError: StateFlow<RelayException?> = mutableError

    public suspend fun load() {
        mutablePermission.value = settings.read().permission
        write { api.load() }
    }

    public fun state(cell: RelayPreferenceCell): RelayPreferenceRowState = RelayPreferenceRowState.of(cell, mutablePermission.value)

    public fun name(category: String): String =
        byKey[category]?.name ?: mutablePreferences.value?.cells(category)?.firstOrNull()?.categoryName ?: category

    /** Turns a cell on, or off; turning a digest category off first asks the three-choice question. */
    public suspend fun set(
        cell: RelayPreferenceCell,
        on: Boolean,
    ) {
        when {
            on -> write { api.set(cell.category, cell.channel, RelayPreferenceValue.OPT_IN) }
            cell.digestAllowed -> mutablePending.value = cell
            else -> write { api.set(cell.category, cell.channel, RelayPreferenceValue.OPT_OUT) }
        }
    }

    public fun cancelTurnOff() {
        mutablePending.value = null
    }

    // PC-17
    public suspend fun choose(choice: RelayTurnOffChoice) {
        val cell = mutablePending.value ?: return
        mutablePending.value = null
        val current = mutablePreferences.value
        when (choice) {
            RelayTurnOffChoice.INSTANT -> {
                current?.let { write { api.setDigest(cell.category, RelayDigestChoice.INSTANT, it) } }
            }

            RelayTurnOffChoice.DIGEST -> {
                current?.let { write { api.setDigest(cell.category, RelayDigestChoice.DIGEST, it) } }
            }

            RelayTurnOffChoice.NEVER -> {
                write { api.set(cell.category, cell.channel, RelayPreferenceValue.OPT_OUT) }
            }
        }
    }

    private suspend fun write(change: suspend () -> RelayPreferences) {
        try {
            mutablePreferences.value = change()
        } catch (error: RelayException) {
            mutableError.value = error
        }
    }
}

/** The display name of a channel. */
@Composable
public fun relayChannelName(channel: String): String {
    val id =
        when (channel) {
            "push" -> R.string.relay_channel_push
            "web_push" -> R.string.relay_channel_web_push
            "email" -> R.string.relay_channel_email
            "sms" -> R.string.relay_channel_sms
            "voice" -> R.string.relay_channel_voice
            "whatsapp" -> R.string.relay_channel_whatsapp
            "slack" -> R.string.relay_channel_slack
            "teams" -> R.string.relay_channel_teams
            "telegram" -> R.string.relay_channel_telegram
            "discord" -> R.string.relay_channel_discord
            "in_app" -> R.string.relay_channel_in_app
            "webhook" -> R.string.relay_channel_webhook
            else -> null
        }
    return if (id != null) stringResource(id) else channel
}

// X-32
// PC-18

/**
 * The preference centre: one section per category with a row per channel. Locked, administrator and
 * device states are shown in words, and turning a digest category off asks three choices.
 */
@Composable
public fun RelayPreferencesScreen(
    model: RelayPreferencesModel,
    modifier: Modifier = Modifier,
    onOpenSettings: (() -> Unit)? = null,
    onRequestPermission: (() -> Unit)? = null,
) {
    val theme = LocalRelayTheme.current
    val preferences by model.preferences.collectAsState()
    val pending by model.pendingTurnOff.collectAsState()
    model.permission.collectAsState()
    val scope = rememberCoroutineScope()
    LaunchedEffect(model) { model.load() }
    LazyColumn(modifier = modifier.background(theme.background)) {
        item {
            Text(
                stringResource(R.string.relay_prefs_title),
                color = theme.primaryText,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(16.dp),
            )
        }
        val current = preferences ?: return@LazyColumn
        current.categories.forEach { category ->
            item(key = "category-$category") {
                Text(
                    model.name(category),
                    color = theme.secondaryText,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 4.dp),
                )
            }
            current.cells(category).forEach { cell ->
                item(key = "cell-$category-${cell.channel}") {
                    RelayPreferenceRow(
                        cell = cell,
                        state = model.state(cell),
                        onChange = { on -> scope.launch { model.set(cell, on) } },
                        onOpenSettings = onOpenSettings,
                        onRequestPermission = onRequestPermission,
                    )
                }
            }
        }
    }
    if (pending != null) {
        AlertDialog(
            onDismissRequest = { model.cancelTurnOff() },
            title = { Text(stringResource(R.string.relay_prefs_off_prompt)) },
            text = {
                Column {
                    TextButton(onClick = { scope.launch { model.choose(RelayTurnOffChoice.INSTANT) } }) {
                        Text(stringResource(R.string.relay_prefs_instant))
                    }
                    TextButton(onClick = { scope.launch { model.choose(RelayTurnOffChoice.DIGEST) } }) {
                        Text(stringResource(R.string.relay_prefs_digest))
                    }
                    TextButton(onClick = { scope.launch { model.choose(RelayTurnOffChoice.NEVER) } }) {
                        Text(stringResource(R.string.relay_prefs_never))
                    }
                }
            },
            confirmButton = {},
            dismissButton = {
                TextButton(onClick = { model.cancelTurnOff() }) { Text(stringResource(R.string.relay_prefs_cancel)) }
            },
        )
    }
}

// X-51
private fun lockText(beneficiary: RelayLockBeneficiary?): Int =
    when (beneficiary) {
        RelayLockBeneficiary.SUBSCRIBER -> R.string.relay_prefs_locked_subscriber
        RelayLockBeneficiary.TENANT -> R.string.relay_prefs_locked_tenant
        null -> R.string.relay_prefs_locked_on
    }

/** One channel row of the preference centre. */
@Composable
public fun RelayPreferenceRow(
    cell: RelayPreferenceCell,
    state: RelayPreferenceRowState,
    onChange: (Boolean) -> Unit,
    onOpenSettings: (() -> Unit)? = null,
    onRequestPermission: (() -> Unit)? = null,
) {
    val theme = LocalRelayTheme.current
    val name = relayChannelName(cell.channel)
    val stateText =
        stringResource(
            when (state) {
                RelayPreferenceRowState.ON -> R.string.relay_prefs_on
                RelayPreferenceRowState.OFF -> R.string.relay_prefs_off
                RelayPreferenceRowState.LOCKED_ON -> lockText(cell.lockBeneficiary)
                RelayPreferenceRowState.ADMIN_DISABLED -> R.string.relay_prefs_admin_disabled
                RelayPreferenceRowState.DEVICE_DISABLED -> R.string.relay_prefs_device_disabled
                RelayPreferenceRowState.PERMISSION_PENDING -> R.string.relay_prefs_permission_pending
            },
        )
    Row(
        modifier =
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp)
                .semantics(mergeDescendants = true) { stateDescription = stateText },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(name, color = theme.primaryText)
            if (!state.isEditable) Text(stateText, color = theme.secondaryText)
        }
        when (state) {
            RelayPreferenceRowState.ON, RelayPreferenceRowState.OFF -> {
                Switch(
                    checked = state == RelayPreferenceRowState.ON,
                    onCheckedChange = onChange,
                    colors = SwitchDefaults.colors(checkedTrackColor = theme.accent),
                )
            }

            RelayPreferenceRowState.DEVICE_DISABLED -> {
                onOpenSettings?.let {
                    TextButton(onClick = it) { Text(stringResource(R.string.relay_prefs_open_settings), color = theme.accent) }
                }
            }

            RelayPreferenceRowState.PERMISSION_PENDING -> {
                onRequestPermission?.let {
                    TextButton(onClick = it) { Text(stringResource(R.string.relay_prefs_allow), color = theme.accent) }
                }
            }

            RelayPreferenceRowState.LOCKED_ON, RelayPreferenceRowState.ADMIN_DISABLED -> {
                Spacer(Modifier)
            }
        }
    }
}
