package com.icamlink.app.stream

import android.util.Base64
import com.icamlink.app.data.StreamQuality
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.ConnectException
import java.net.InetSocketAddress
import java.net.NoRouteToHostException
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.security.MessageDigest
import java.security.SecureRandom

sealed class ProbeResult(val message: String, val ok: Boolean) {
    data object Ok : ProbeResult("Conexión exitosa: el flujo RTSP responde.", true)
    data object BadCredentials : ProbeResult("Usuario o contraseña RTSP incorrectos.", false)
    data object NotFound : ProbeResult("La cámara respondió, pero no existe la ruta /stream2.", false)
    data object Unreachable : ProbeResult("No se pudo alcanzar la cámara (revisa IP, puerto y red).", false)
    data class Failure(val detail: String) : ProbeResult("Error: $detail", false)
}

/**
 * Connection test using a bare RTSP DESCRIBE (Digest/Basic) on the sub stream. It tells apart
 * bad credentials from an unreachable host, and the socket is closed right away so it doesn't
 * keep a camera slot busy the way a real player would.
 */
object RtspProbe {
    private const val CONNECT_MS = 3_000
    private const val READ_MS = 4_000

    suspend fun probe(host: String, port: Int, user: String, pass: String): ProbeResult =
        withContext(Dispatchers.IO) {
            val uri = "rtsp://$host:$port/${StreamQuality.SUB.path}"
            try {
                val (code, headers) = describe(host, port, uri, null)
                when (code) {
                    200 -> ProbeResult.Ok
                    401 -> {
                        val auth = authHeader(headers, uri, user, pass)
                            ?: return@withContext ProbeResult.Failure("método de autenticación no soportado")
                        when (val second = describe(host, port, uri, auth).first) {
                            200 -> ProbeResult.Ok
                            401, 403 -> ProbeResult.BadCredentials
                            404 -> ProbeResult.NotFound
                            else -> ProbeResult.Failure("respuesta RTSP $second")
                        }
                    }
                    404 -> ProbeResult.NotFound
                    else -> ProbeResult.Failure("respuesta RTSP $code")
                }
            } catch (e: SocketTimeoutException) {
                ProbeResult.Unreachable
            } catch (e: ConnectException) {
                ProbeResult.Unreachable
            } catch (e: NoRouteToHostException) {
                ProbeResult.Unreachable
            } catch (e: UnknownHostException) {
                ProbeResult.Unreachable
            } catch (e: Exception) {
                ProbeResult.Failure(e.message ?: e.javaClass.simpleName)
            }
        }

    private fun describe(host: String, port: Int, uri: String, auth: String?): Pair<Int, List<String>> {
        Socket().use { s ->
            s.connect(InetSocketAddress(host, port), CONNECT_MS)
            s.soTimeout = READ_MS
            val request = buildString {
                append("DESCRIBE $uri RTSP/1.0\r\nCSeq: 1\r\nAccept: application/sdp\r\nUser-Agent: iCamLink\r\n")
                if (auth != null) append("Authorization: $auth\r\n")
                append("\r\n")
            }
            s.getOutputStream().apply {
                write(request.toByteArray())
                flush()
            }
            val reader = s.getInputStream().bufferedReader(Charsets.ISO_8859_1)
            val status = reader.readLine() ?: error("sin respuesta")
            val code = status.split(' ').getOrNull(1)?.toIntOrNull() ?: error("respuesta inválida")
            val headers = generateSequence { reader.readLine() }.takeWhile { it.isNotEmpty() }.toList()
            return code to headers
        }
    }

    private fun authHeader(headers: List<String>, uri: String, user: String, pass: String): String? {
        val challenges = headers
            .filter { it.startsWith("WWW-Authenticate:", ignoreCase = true) }
            .map { it.substringAfter(':').trim() }

        challenges.firstOrNull { it.startsWith("Digest", ignoreCase = true) }?.let { challenge ->
            val params = PARAM.findAll(challenge.substringAfter(' ')).associate {
                it.groupValues[1].lowercase() to it.groupValues[2].ifEmpty { it.groupValues[3] }
            }
            val nonce = params["nonce"] ?: return null
            val realm = params["realm"].orEmpty()
            val ha1 = md5("$user:$realm:$pass")
            val ha2 = md5("DESCRIBE:$uri")
            val qop = params["qop"]?.split(',')?.map { it.trim() }?.firstOrNull { it == "auth" }
            val nc = "00000001"
            val cnonce = ByteArray(8).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
            val response = if (qop != null) md5("$ha1:$nonce:$nc:$cnonce:$qop:$ha2") else md5("$ha1:$nonce:$ha2")
            return buildString {
                append("Digest username=\"$user\", realm=\"$realm\", nonce=\"$nonce\", uri=\"$uri\", response=\"$response\"")
                if (qop != null) append(", qop=$qop, nc=$nc, cnonce=\"$cnonce\"")
            }
        }
        if (challenges.any { it.startsWith("Basic", ignoreCase = true) }) {
            return "Basic " + Base64.encodeToString("$user:$pass".toByteArray(), Base64.NO_WRAP)
        }
        return null
    }

    private val PARAM = Regex("""(\w+)=(?:"([^"]*)"|([^,\s]*))""")

    private fun md5(s: String): String =
        MessageDigest.getInstance("MD5").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }
}
