package com.icamlink.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.icamlink.app.data.Camera
import com.icamlink.app.data.StreamQuality
import com.icamlink.app.stream.RtspSession
import com.icamlink.app.stream.StreamManager
import com.icamlink.app.stream.StreamState
import org.videolan.libvlc.util.VLCVideoLayout

/**
 * Plays one camera at one quality. Leaving the composition (deselected, scrolled out, mode
 * switch, app in background) stops and releases the player so its RTSP slot is freed.
 * [volume] == null means a muted preview (audio isn't even requested).
 */
@Composable
fun CameraVideo(
    camera: Camera,
    quality: StreamQuality,
    volume: Int?,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val audio = volume != null
    val session = remember(camera.id, camera.host, camera.port, camera.username, camera.password, quality, audio) {
        RtspSession(StreamManager.vlc(context), camera, quality, audio)
    }
    val layout = remember(session) { VLCVideoLayout(context) }

    DisposableEffect(session) {
        session.attach(layout)
        onDispose { session.release() }
    }
    LaunchedEffect(session, volume) { session.setVolume(volume ?: 0) }

    Box(modifier.background(Color.Black)) {
        key(session) {
            AndroidView(factory = { layout }, modifier = Modifier.fillMaxSize())
        }
        StatusOverlay(session.state)
    }
}

@Composable
private fun BoxScope.StatusOverlay(state: StreamState) {
    if (state is StreamState.Live) return
    val (text, color) = when (state) {
        is StreamState.Reconnecting -> "Reconectando…" to ICamColors.Warn
        else -> "Conectando…" to ICamColors.AccentSoft
    }
    Row(
        Modifier
            .align(Alignment.Center)
            .background(ICamColors.Scrim, RoundedCornerShape(20.dp))
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        CircularProgressIndicator(Modifier.size(14.dp), color = color, strokeWidth = 2.dp)
        Text(text, color = color, fontSize = 11.sp, style = MaterialTheme.typography.labelSmall)
    }
}
