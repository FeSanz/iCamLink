package com.icamlink.app.stream

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.videolan.libvlc.LibVLC

/**
 * Tapo cameras only accept a handful of simultaneous RTSP clients, so a new session for a camera
 * must never start while the previous one for that same camera is still tearing down.
 * Teardowns are serialized per camera here and new sessions wait for them ([awaitFree]).
 */
object StreamManager {
    /** App-wide scope: teardowns must finish even when the composable that owned the player is gone. */
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private val teardowns = HashMap<String, Job>() // main thread only

    @Volatile
    private var vlc: LibVLC? = null

    fun vlc(context: Context): LibVLC = vlc ?: synchronized(this) {
        vlc ?: LibVLC(
            context.applicationContext,
            arrayListOf("--no-stats", "--drop-late-frames", "--skip-frames", "--no-osd"),
        ).also { vlc = it }
    }

    suspend fun awaitFree(cameraId: String) {
        teardowns[cameraId]?.join()
    }

    fun teardown(cameraId: String, block: () -> Unit) {
        val previous = teardowns[cameraId]
        teardowns[cameraId] = scope.launch {
            previous?.join()
            withContext(Dispatchers.IO) {
                block()
                delay(SLOT_RELEASE_GRACE_MS) // let the camera notice the TEARDOWN and free the slot
            }
        }
    }

    private const val SLOT_RELEASE_GRACE_MS = 250L
}
