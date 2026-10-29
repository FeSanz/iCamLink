package com.icamlink.app

import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.util.Rational
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.runtime.snapshotFlow
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.lifecycleScope
import com.icamlink.app.ui.AppViewModel
import com.icamlink.app.ui.ICamLinkApp
import com.icamlink.app.ui.ICamLinkTheme
import com.icamlink.app.ui.Screen
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val vm: AppViewModel by viewModels()

    private val muteReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_TOGGLE_MUTE) vm.toggleMute()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.attributes = window.attributes.apply {
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
        setContent { ICamLinkTheme { ICamLinkApp(vm) } }

        // Keep the picture-in-picture params in step with what the app can show: on Android 12+ the
        // system enters PiP by itself when the user leaves (home/recents), earlier versions use
        // onUserLeaveHint. The window's mute button reflects the current volume.
        lifecycleScope.launch {
            snapshotFlow { Triple(vm.screen, vm.selectedCamera?.id, vm.volume == 0) }.collect { updatePipParams() }
        }
    }

    // --- picture-in-picture --------------------------------------------------------------------

    private fun canEnterPip(): Boolean =
        packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE) &&
            vm.screen == Screen.Viewer && vm.selectedCamera != null

    private fun pipParams(): PictureInPictureParams {
        val muted = vm.volume == 0
        val title = if (muted) "Activar sonido" else "Silenciar"
        val action = RemoteAction(
            Icon.createWithResource(this, if (muted) R.drawable.ic_pip_volume_off else R.drawable.ic_pip_volume_on),
            title,
            title,
            PendingIntent.getBroadcast(
                this,
                0,
                Intent(ACTION_TOGGLE_MUTE).setPackage(packageName),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            ),
        )
        return PictureInPictureParams.Builder()
            .setAspectRatio(Rational(16, 9))
            .setActions(listOf(action))
            .apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    setAutoEnterEnabled(canEnterPip())
                    setSeamlessResizeEnabled(false)
                }
            }
            .build()
    }

    private fun updatePipParams() {
        if (!packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) return
        setPictureInPictureParams(pipParams())
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S && canEnterPip()) enterPictureInPictureMode(pipParams())
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        vm.updateInPip(isInPictureInPictureMode)
        if (isInPictureInPictureMode) {
            ContextCompat.registerReceiver(this, muteReceiver, IntentFilter(ACTION_TOGGLE_MUTE), ContextCompat.RECEIVER_NOT_EXPORTED)
        } else {
            runCatching { unregisterReceiver(muteReceiver) }
        }
    }

    private companion object {
        const val ACTION_TOGGLE_MUTE = "com.icamlink.app.TOGGLE_MUTE"
    }
}
