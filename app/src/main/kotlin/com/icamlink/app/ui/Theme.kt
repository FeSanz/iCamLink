package com.icamlink.app.ui

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/** Palette taken from the app icon: orange accent over dark slate blues. */
object ICamColors {
    val Accent = Color(0xFFE8782B)
    val AccentSoft = Color(0xFFFFD9BF)
    val AccentContainer = Color(0xFF4A2E1B)
    val Background = Color(0xFF0F212C)
    val Surface = Color(0xFF1B3240)
    val SurfaceVariant = Color(0xFF254255)
    val OnSurface = Color(0xFFE6E1E5)
    val Muted = Color(0xFF8FA3AF)
    val Outline = Color(0xFF3A5466)
    val Live = Color(0xFF22C55E)
    val Warn = Color(0xFFFFC107)
    val Error = Color(0xFFE53935)
    val Scrim = Color(0x8C000000)
}

private val Scheme = darkColorScheme(
    primary = ICamColors.Accent,
    onPrimary = Color(0xFF142B39),
    primaryContainer = ICamColors.AccentContainer,
    onPrimaryContainer = ICamColors.AccentSoft,
    background = ICamColors.Background,
    onBackground = ICamColors.OnSurface,
    surface = ICamColors.Surface,
    onSurface = ICamColors.OnSurface,
    surfaceVariant = ICamColors.SurfaceVariant,
    onSurfaceVariant = ICamColors.Muted,
    outline = ICamColors.Outline,
    error = ICamColors.Error,
)

private val AppShapes = Shapes(
    small = RoundedCornerShape(8.dp),
    medium = RoundedCornerShape(12.dp),
    large = RoundedCornerShape(20.dp),
)

// Surveillance view: always dark, like NotiLink's night variant.
@Composable
fun ICamLinkTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = Scheme, shapes = AppShapes, content = content)
}
