package com.icamlink.app.data

import java.util.UUID

/** Tapo exposes the HD feed on /stream1 and a low-resolution feed on /stream2. */
enum class StreamQuality(val path: String) {
    MAIN("stream1"),
    SUB("stream2"),
}

data class Camera(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val host: String,
    val port: Int = 554,
    val username: String,
    val password: String,
) {
    /** Credentials are passed to LibVLC as options, never embedded in the URL (special characters). */
    fun rtspUrl(quality: StreamQuality): String = "rtsp://$host:$port/${quality.path}"
}

enum class ViewMode { Focus, Grid }
