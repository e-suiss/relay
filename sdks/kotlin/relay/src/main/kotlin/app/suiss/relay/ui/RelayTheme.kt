package app.suiss.relay.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

// X-32

/** Colours and shapes of the Relay components; a brand (or a subtenant brand) sets its own values. */
@Immutable
public data class RelayTheme(
    val accent: Color = Color(0xFF2457C5),
    val background: Color = Color.Unspecified,
    val primaryText: Color = Color(0xFF1B1B1F),
    val secondaryText: Color = Color(0xFF4A4A52),
    val unreadIndicator: Color = Color(0xFF2457C5),
    val onAccent: Color = Color.White,
    val destructive: Color = Color(0xFFB3261E),
    val cornerRadius: Dp = 12.dp,
)

/** The theme the Relay components read. */
public val LocalRelayTheme: androidx.compose.runtime.ProvidableCompositionLocal<RelayTheme> =
    staticCompositionLocalOf { RelayTheme() }

/** Sets the theme of the Relay components inside [content]. */
@Composable
public fun RelayThemeProvider(
    theme: RelayTheme,
    content: @Composable () -> Unit,
) {
    CompositionLocalProvider(LocalRelayTheme provides theme, content = content)
}
