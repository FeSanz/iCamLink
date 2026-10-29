package com.icamlink.app.data

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.json.JSONArray
import org.json.JSONObject

class CameraStore(context: Context) {
    private val secure: SharedPreferences = createSecurePrefs(context)
    private val ui: SharedPreferences = context.getSharedPreferences("icamlink_ui", Context.MODE_PRIVATE)

    fun loadCameras(): List<Camera> = runCatching {
        val arr = JSONArray(secure.getString(KEY_CAMERAS, null) ?: "[]")
        List(arr.length()) { i ->
            val o = arr.getJSONObject(i)
            Camera(
                id = o.getString("id"),
                name = o.getString("name"),
                host = o.getString("host"),
                port = o.optInt("port", 554),
                username = o.optString("user"),
                password = o.optString("pass"),
            )
        }
    }.getOrDefault(emptyList())

    fun saveCameras(cameras: List<Camera>) {
        val arr = JSONArray()
        cameras.forEach {
            arr.put(
                JSONObject()
                    .put("id", it.id)
                    .put("name", it.name)
                    .put("host", it.host)
                    .put("port", it.port)
                    .put("user", it.username)
                    .put("pass", it.password)
            )
        }
        secure.edit().putString(KEY_CAMERAS, arr.toString()).apply()
    }

    var selectedId: String?
        get() = ui.getString("selected", null)
        set(v) = ui.edit().putString("selected", v).apply()

    var mode: ViewMode
        get() = runCatching { ViewMode.valueOf(ui.getString("mode", null) ?: "") }.getOrDefault(ViewMode.Focus)
        set(v) = ui.edit().putString("mode", v.name).apply()

    var volume: Int
        get() = ui.getInt("volume", 60)
        set(v) = ui.edit().putInt("volume", v).apply()

    private companion object {
        const val KEY_CAMERAS = "cameras"

        fun createSecurePrefs(context: Context): SharedPreferences = try {
            val key = MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
            EncryptedSharedPreferences.create(
                context,
                "icamlink_cameras",
                key,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
        } catch (e: Exception) {
            // Keystore can be unusable on some devices/emulators; degrade rather than lose the app.
            context.getSharedPreferences("icamlink_cameras_plain", Context.MODE_PRIVATE)
        }
    }
}
