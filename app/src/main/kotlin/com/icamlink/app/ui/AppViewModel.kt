package com.icamlink.app.ui

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.icamlink.app.data.Camera
import com.icamlink.app.data.CameraStore
import com.icamlink.app.data.ViewMode
import com.icamlink.app.discovery.DiscoveredCamera
import com.icamlink.app.discovery.OnvifDiscovery
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

enum class Screen { Viewer, Settings }

class AppViewModel(app: Application) : AndroidViewModel(app) {
    private val store = CameraStore(app)
    private val discovery = OnvifDiscovery(app)

    var cameras by mutableStateOf(store.loadCameras())
        private set
    var mode by mutableStateOf(store.mode)
        private set
    var volume by mutableIntStateOf(store.volume)
        private set
    var screen by mutableStateOf(Screen.Viewer)
        private set
    private var selectedId by mutableStateOf(store.selectedId)

    /** True while the activity is shown in the system picture-in-picture window. */
    var inPip by mutableStateOf(false)
        private set

    fun updateInPip(value: Boolean) {
        inPip = value
    }

    /** Falls back to the first camera when nothing (valid) is selected. */
    val selectedCamera: Camera? get() = cameras.firstOrNull { it.id == selectedId } ?: cameras.firstOrNull()

    private var volumeBeforeMute = volume.takeIf { it > 0 } ?: 60

    fun select(id: String) {
        selectedId = id
        store.selectedId = id
    }

    fun focusOn(id: String) {
        select(id)
        changeMode(ViewMode.Focus)
    }

    fun toggleMode() = changeMode(if (mode == ViewMode.Focus) ViewMode.Grid else ViewMode.Focus)

    private fun changeMode(value: ViewMode) {
        mode = value
        store.mode = value
    }

    fun updateVolume(value: Int) {
        volume = value.coerceIn(0, 100)
        if (volume > 0) volumeBeforeMute = volume
        store.volume = volume
    }

    fun toggleMute() = updateVolume(if (volume == 0) volumeBeforeMute else 0)

    fun openSettings() {
        screen = Screen.Settings
    }

    fun closeSettings() {
        stopScan()
        screen = Screen.Viewer
    }

    fun upsert(camera: Camera) {
        cameras = if (cameras.any { it.id == camera.id }) {
            cameras.map { if (it.id == camera.id) camera else it }
        } else {
            cameras + camera
        }
        store.saveCameras(cameras)
    }

    fun move(from: Int, to: Int) {
        if (from == to || from !in cameras.indices || to !in cameras.indices) return
        cameras = cameras.toMutableList().apply { add(to, removeAt(from)) }
        store.saveCameras(cameras)
    }

    fun delete(id: String) {
        cameras = cameras.filterNot { it.id == id }
        store.saveCameras(cameras)
    }

    fun isRegistered(host: String) = cameras.any { it.host == host }

    fun addDiscovered(selected: List<DiscoveredCamera>, username: String, password: String) {
        val added = selected.filterNot { isRegistered(it.host) }.mapIndexed { i, found ->
            Camera(
                name = found.name ?: "Cámara ${cameras.size + i + 1}",
                host = found.host,
                username = username,
                password = password,
            )
        }
        cameras = cameras + added
        store.saveCameras(cameras)
    }

    // --- network scan -------------------------------------------------------------------------

    var scanning by mutableStateOf(false)
        private set
    var scanProgress by mutableFloatStateOf(0f)
        private set
    var scanError by mutableStateOf<String?>(null)
        private set
    var found by mutableStateOf<List<DiscoveredCamera>>(emptyList())
        private set
    private var scanJob: Job? = null

    fun startScan() {
        scanJob?.cancel()
        found = emptyList()
        scanError = null
        scanProgress = 0f
        scanJob = viewModelScope.launch {
            scanning = true
            try {
                discovery.scan { list, progress ->
                    found = list
                    scanProgress = progress
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                scanError = e.message ?: "Error al escanear la red."
            } finally {
                scanning = false
            }
        }
    }

    fun stopScan() {
        scanJob?.cancel()
    }
}
