package com.icamlink.app.stream

import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.icamlink.app.data.Camera
import com.icamlink.app.data.StreamQuality
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.util.VLCVideoLayout

sealed interface StreamState {
    data object Connecting : StreamState
    data object Live : StreamState
    data class Reconnecting(val attempt: Int) : StreamState
}

/**
 * One RTSP connection (one LibVLC player) to one camera at one quality.
 * The player is created lazily in [attach] and fully stopped/released in [release].
 */
class RtspSession(
    private val vlc: LibVLC,
    private val camera: Camera,
    private val quality: StreamQuality,
    private val audio: Boolean,
) {
    var state by mutableStateOf<StreamState>(StreamState.Connecting)
        private set

    private enum class Signal { Playing, Alive, Failed }

    private val signals = Channel<Signal>(Channel.UNLIMITED)
    private var player: MediaPlayer? = null
    private var job: Job? = null
    private var released = false
    private var volume = 0

    fun attach(layout: VLCVideoLayout) {
        if (released || player != null) return
        val p = MediaPlayer(vlc)
        p.attachViews(layout, null, false, false)
        p.videoScale = MediaPlayer.ScaleType.SURFACE_BEST_FIT
        p.setEventListener(MediaPlayer.EventListener { e ->
            when (e.type) {
                MediaPlayer.Event.Playing -> signals.trySend(Signal.Playing)
                MediaPlayer.Event.EncounteredError, MediaPlayer.Event.EndReached -> signals.trySend(Signal.Failed)
                MediaPlayer.Event.Buffering, MediaPlayer.Event.TimeChanged,
                MediaPlayer.Event.PositionChanged, MediaPlayer.Event.Opening -> signals.trySend(Signal.Alive)
            }
        })
        player = p
        job = StreamManager.scope.launch { run(p) }
    }

    fun setVolume(percent: Int) {
        volume = percent
        player?.setVolume(percent)
    }

    fun release() {
        if (released) return
        released = true
        job?.cancel()
        val p = player ?: return
        player = null
        p.setEventListener(null)
        p.detachViews()
        // stop() may block on the RTSP TEARDOWN, so it runs off the main thread, serialized per camera.
        StreamManager.teardown(camera.id) {
            p.stop()
            p.release()
        }
    }

    private suspend fun run(p: MediaPlayer) {
        delay(START_DEBOUNCE_MS) // rapid selection changes never reach the camera
        StreamManager.awaitFree(camera.id)
        var attempt = 0
        while (currentCoroutineContext().isActive) {
            state = if (attempt == 0) StreamState.Connecting else StreamState.Reconnecting(attempt)
            while (signals.tryReceive().isSuccess) Unit
            play(p)

            var playing = false
            while (true) {
                val timeout = if (playing) STALL_TIMEOUT_MS else CONNECT_TIMEOUT_MS
                val signal = withTimeoutOrNull(timeout) { signals.receive() }
                if (signal == null || signal == Signal.Failed) break
                if (signal == Signal.Playing) {
                    if (!playing) {
                        playing = true
                        attempt = 0
                        p.setVolume(volume)
                    }
                    state = StreamState.Live
                }
            }

            withContext(Dispatchers.IO) { p.stop() }
            attempt++
            state = StreamState.Reconnecting(attempt)
            delay(minOf(RETRY_STEP_MS * attempt, RETRY_MAX_MS))
        }
    }

    private fun play(p: MediaPlayer) {
        val media = Media(vlc, Uri.parse(camera.rtspUrl(quality)))
        media.setHWDecoderEnabled(true, false)
        media.addOption(":network-caching=300")
        media.addOption(":live-caching=300")
        media.addOption(":rtsp-tcp")
        media.addOption(":clock-jitter=0")
        media.addOption(":clock-synchro=0")
        media.addOption(":rtsp-user=${camera.username}")
        media.addOption(":rtsp-pwd=${camera.password}")
        if (!audio) media.addOption(":no-audio")
        p.media = media
        media.release() // the player keeps its own reference
        p.play()
    }

    private companion object {
        const val START_DEBOUNCE_MS = 150L
        const val CONNECT_TIMEOUT_MS = 10_000L
        const val STALL_TIMEOUT_MS = 6_000L
        const val RETRY_STEP_MS = 1_000L
        const val RETRY_MAX_MS = 8_000L
    }
}
