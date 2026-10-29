package com.icamlink.app.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.VideocamOff
import androidx.compose.material.icons.filled.ViewSidebar
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalMinimumInteractiveComponentSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.key
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.icamlink.app.data.Camera
import com.icamlink.app.data.StreamQuality
import com.icamlink.app.data.ViewMode
import kotlin.math.ceil
import kotlin.math.min
import kotlin.math.roundToInt

@Composable
fun ViewerScreen(vm: AppViewModel) {
    if (vm.inPip) {
        // System picture-in-picture window: just the selected camera's HD stream (and its audio).
        vm.selectedCamera?.let { camera ->
            key(camera.id) { CameraVideo(camera, StreamQuality.MAIN, vm.volume, Modifier.fillMaxSize()) }
        }
        return
    }
    Box(
        Modifier
            .fillMaxSize()
            .background(ICamColors.Background)
            .windowInsetsPadding(WindowInsets.displayCutout)
    ) {
        when {
            vm.cameras.isEmpty() -> EmptyState(onOpenSettings = vm::openSettings)
            vm.mode == ViewMode.Focus -> FocusLayout(vm)
            else -> GridLayout(vm)
        }
        FloatingControls(vm, Modifier.align(Alignment.TopEnd).padding(12.dp))
    }
}

// --- Mode 1: sidebar of thumbnails + main stream ------------------------------------------------

@Composable
private fun FocusLayout(vm: AppViewModel) {
    val selected = vm.selectedCamera
    Row(Modifier.fillMaxSize()) {
        LazyColumn(
            Modifier
                .width(188.dp)
                .fillMaxHeight()
                .background(ICamColors.Surface),
            contentPadding = PaddingValues(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            // Only composed (= connected) while visible, so scrolled-away rows free their stream.
            items(vm.cameras, key = { it.id }) { camera ->
                Thumbnail(
                    camera = camera,
                    isSelected = camera.id == selected?.id,
                    onClick = { vm.select(camera.id) },
                )
            }
        }
        Box(Modifier.weight(1f).fillMaxHeight()) {
            if (selected != null) {
                key(selected.id) {
                    CameraVideo(selected, StreamQuality.MAIN, vm.volume, Modifier.fillMaxSize())
                }
                CameraLabel(selected.name, Modifier.align(Alignment.TopStart).padding(12.dp))
            }
            VolumeBar(vm, Modifier.align(Alignment.BottomStart).padding(12.dp))
        }
    }
}

@Composable
private fun Thumbnail(camera: Camera, isSelected: Boolean, onClick: () -> Unit) {
    val shape = MaterialTheme.shapes.small
    Box(
        Modifier
            .fillMaxWidth()
            .aspectRatio(16f / 9f)
            .clip(shape)
            .border(
                BorderStroke(if (isSelected) 2.dp else 1.dp, if (isSelected) ICamColors.Accent else ICamColors.Outline),
                shape,
            )
    ) {
        if (isSelected) {
            // The camera is already streaming in HD in the main view; a second connection would waste a slot.
            Box(
                Modifier.fillMaxSize().background(ICamColors.AccentContainer),
                contentAlignment = Alignment.Center,
            ) {
                Text("En vista principal", color = ICamColors.AccentSoft, fontSize = 11.sp)
            }
        } else {
            CameraVideo(camera, StreamQuality.SUB, null, Modifier.fillMaxSize())
        }
        CameraLabel(camera.name, Modifier.align(Alignment.BottomStart).padding(4.dp))
        Box(Modifier.fillMaxSize().clickable(onClick = onClick))
    }
}

@Composable
private fun CameraLabel(name: String, modifier: Modifier = Modifier) {
    Text(
        name,
        modifier = modifier
            .background(ICamColors.Scrim, RoundedCornerShape(8.dp))
            .padding(horizontal = 8.dp, vertical = 2.dp),
        color = Color.White,
        fontSize = 11.sp,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

// --- Mode 2: proportional grid ------------------------------------------------------------------

@Composable
private fun GridLayout(vm: AppViewModel) {
    val cameras = vm.cameras
    BoxWithConstraints(Modifier.fillMaxSize().padding(2.dp)) {
        val (cols, rows) = bestGrid(cameras.size, maxWidth, maxHeight)
        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            for (r in 0 until rows) {
                Row(
                    Modifier.weight(1f).fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    for (c in 0 until cols) {
                        Box(Modifier.weight(1f).fillMaxHeight()) {
                            cameras.getOrNull(r * cols + c)?.let { camera ->
                                key(camera.id) {
                                    CameraVideo(camera, StreamQuality.SUB, null, Modifier.fillMaxSize())
                                    CameraLabel(camera.name, Modifier.align(Alignment.BottomStart).padding(6.dp))
                                    Box(Modifier.fillMaxSize().clickable { vm.focusOn(camera.id) })
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Picks the cols×rows layout whose 16:9 cells come out largest (3→2x2, 4→2x2, 6→3x2, ...). */
private fun bestGrid(count: Int, width: Dp, height: Dp): Pair<Int, Int> {
    var best = 1 to count.coerceAtLeast(1)
    var bestSize = 0f
    for (cols in 1..count.coerceAtLeast(1)) {
        val rows = ceil(count / cols.toFloat()).toInt()
        val cellW = width.value / cols
        val cellH = height.value / rows
        val size = min(cellW, cellH * 16f / 9f)
        if (size > bestSize * 0.999f) {
            bestSize = size
            best = cols to rows
        }
    }
    return best
}

// --- Floating controls --------------------------------------------------------------------------

@Composable
private fun FloatingControls(vm: AppViewModel, modifier: Modifier) {
    Row(
        modifier
            .clip(RoundedCornerShape(20.dp))
            .background(ICamColors.Scrim)
            .padding(horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = vm::toggleMode, enabled = vm.cameras.isNotEmpty(), modifier = Modifier.size(40.dp)) {
            Icon(
                if (vm.mode == ViewMode.Focus) Icons.Filled.GridView else Icons.Filled.ViewSidebar,
                contentDescription = if (vm.mode == ViewMode.Focus) "Vista en cuadrícula" else "Vista principal",
                tint = Color.White,
            )
        }
        IconButton(onClick = vm::openSettings, modifier = Modifier.size(40.dp)) {
            Icon(Icons.Filled.Settings, contentDescription = "Configuración", tint = Color.White)
        }
    }
}

@Composable
private fun VolumeBar(vm: AppViewModel, modifier: Modifier) {
    Row(
        modifier
            .clip(RoundedCornerShape(20.dp))
            .background(ICamColors.Scrim)
            .padding(start = 10.dp, end = 12.dp, top = 5.dp, bottom = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(
            if (vm.volume == 0) Icons.Filled.VolumeOff else Icons.Filled.VolumeUp,
            contentDescription = "Silenciar",
            tint = Color.White,
            modifier = Modifier.size(18.dp).clickable(onClick = vm::toggleMute),
        )
        ThinVolumeSlider(vm.volume, vm::updateVolume, Modifier.width(150.dp))
    }
}

/** Thin 0..100 volume slider with an accent thumb, shared by the main view and the mini player. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ThinVolumeSlider(volume: Int, onVolume: (Int) -> Unit, modifier: Modifier = Modifier) {
    CompositionLocalProvider(LocalMinimumInteractiveComponentSize provides Dp.Unspecified) {
        Slider(
            value = volume / 100f,
            onValueChange = { onVolume((it * 100).roundToInt()) },
            modifier = modifier,
            thumb = { Spacer(Modifier.size(14.dp).background(ICamColors.Accent, CircleShape)) },
            track = { state ->
                SliderDefaults.Track(
                    sliderState = state,
                    modifier = Modifier.height(3.dp),
                    thumbTrackGapSize = 0.dp,
                    trackInsideCornerSize = 0.dp,
                    colors = SliderDefaults.colors(
                        activeTrackColor = ICamColors.Accent,
                        inactiveTrackColor = Color.White.copy(alpha = 0.3f),
                    ),
                )
            },
        )
    }
}

@Composable
private fun EmptyState(onOpenSettings: () -> Unit) {
    Column(
        Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(Icons.Filled.VideocamOff, null, Modifier.size(48.dp), tint = ICamColors.Muted)
        Spacer(Modifier.size(12.dp))
        Text("No hay cámaras registradas", color = ICamColors.OnSurface, style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.size(16.dp))
        Button(onClick = onOpenSettings, shape = MaterialTheme.shapes.large) { Text("Agregar cámaras") }
    }
}
