package com.icamlink.app.discovery

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.SystemClock
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

data class DiscoveredCamera(
    val host: String,
    val name: String?,
    /** True when it answered WS-Discovery or has the ONVIF port (2020) open; false = only RTSP (554). */
    val onvif: Boolean,
)

class NoLocalNetworkException : Exception("No hay conexión a una red local (Wi-Fi).")

/**
 * Finds ONVIF cameras: a WS-Discovery multicast probe (UDP 3702) runs alongside a /24 sweep for
 * Tapo's ONVIF port (2020) and the RTSP port (554), since some routers block multicast.
 */
class OnvifDiscovery(context: Context) {
    private val appContext = context.applicationContext

    suspend fun scan(onUpdate: (cameras: List<DiscoveredCamera>, progress: Float) -> Unit) = coroutineScope {
        val cm = appContext.getSystemService(ConnectivityManager::class.java)
        val network = cm.activeNetwork
        val localIp = localIpv4(cm, network) ?: throw NoLocalNetworkException()

        val found = ConcurrentHashMap<String, DiscoveredCamera>()
        val done = AtomicInteger(0)
        var wsDone = false

        fun publish() {
            val progress = (done.get() / 254f * 0.85f + if (wsDone) 0.15f else 0f).coerceAtMost(1f)
            onUpdate(found.values.sortedBy { ipKey(it.host) }, progress)
        }

        val wifi = appContext.getSystemService(WifiManager::class.java)
        val lock = wifi.createMulticastLock("icamlink-ws-discovery").apply {
            setReferenceCounted(false)
            acquire()
        }
        try {
            val ws = launch(Dispatchers.IO) {
                wsDiscovery(network, found, ::publish)
                wsDone = true
                publish()
            }

            val prefix = localIp.substringBeforeLast('.')
            val gate = Semaphore(64)
            (1..254).map { i ->
                async(Dispatchers.IO) {
                    val host = "$prefix.$i"
                    if (host != localIp) gate.withPermit {
                        val onvif = portOpen(host, ONVIF_PORT)
                        if (onvif || portOpen(host, RTSP_PORT)) {
                            found.merge(host, DiscoveredCamera(host, null, onvif)) { old, new ->
                                old.copy(onvif = old.onvif || new.onvif)
                            }
                        }
                    }
                    if (done.incrementAndGet() % 8 == 0) publish()
                }
            }.awaitAll()
            ws.join()
            publish()
        } finally {
            if (lock.isHeld) lock.release()
        }
    }

    private fun wsDiscovery(
        network: Network?,
        found: ConcurrentHashMap<String, DiscoveredCamera>,
        onFound: () -> Unit,
    ) {
        DatagramSocket().use { socket ->
            network?.bindSocket(socket)
            socket.soTimeout = 500
            val probe = probeXml().toByteArray()
            val group = InetAddress.getByName(WS_DISCOVERY_ADDRESS)
            val buffer = ByteArray(16 * 1024)
            val end = SystemClock.elapsedRealtime() + WS_WINDOW_MS
            var lastSend = 0L
            while (SystemClock.elapsedRealtime() < end) {
                val now = SystemClock.elapsedRealtime()
                if (now - lastSend >= 1500) {
                    socket.send(DatagramPacket(probe, probe.size, group, WS_DISCOVERY_PORT))
                    lastSend = now
                }
                try {
                    val packet = DatagramPacket(buffer, buffer.size)
                    socket.receive(packet)
                    val text = String(packet.data, 0, packet.length)
                    val host = XADDRS.find(text)?.let { HOST_IN_URL.find(it.groupValues[1])?.groupValues?.get(1) }
                        ?: packet.address.hostAddress
                        ?: continue
                    val name = SCOPE_NAME.find(text)?.groupValues?.get(1)?.let { Uri.decode(it) }
                        ?: SCOPE_HARDWARE.find(text)?.groupValues?.get(1)?.let { Uri.decode(it) }
                    found.merge(host, DiscoveredCamera(host, name, true)) { old, new ->
                        old.copy(name = old.name ?: new.name, onvif = true)
                    }
                    onFound()
                } catch (_: SocketTimeoutException) {
                    // keep listening until the window closes
                }
            }
        }
    }

    private fun portOpen(host: String, port: Int): Boolean = try {
        Socket().use { it.connect(InetSocketAddress(host, port), PORT_TIMEOUT_MS) }
        true
    } catch (_: Exception) {
        false
    }

    private fun localIpv4(cm: ConnectivityManager, network: Network?): String? =
        network?.let { cm.getLinkProperties(it) }?.linkAddresses
            ?.map { it.address }
            ?.filterIsInstance<Inet4Address>()
            ?.firstOrNull { !it.isLoopbackAddress }
            ?.hostAddress

    private fun ipKey(ip: String): Long =
        ip.split('.').fold(0L) { acc, part -> acc * 256 + (part.toLongOrNull() ?: 0) }

    private fun probeXml(): String = """<?xml version="1.0" encoding="UTF-8"?>
<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl"><e:Header><w:MessageID>uuid:${UUID.randomUUID()}</w:MessageID><w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To><w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header><e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>"""

    private companion object {
        const val WS_DISCOVERY_ADDRESS = "239.255.255.250"
        const val WS_DISCOVERY_PORT = 3702
        const val WS_WINDOW_MS = 4_000L
        const val ONVIF_PORT = 2020
        const val RTSP_PORT = 554
        const val PORT_TIMEOUT_MS = 600

        val XADDRS = Regex("""XAddrs>\s*([^<]+)<""")
        val HOST_IN_URL = Regex("""https?://(\d{1,3}(?:\.\d{1,3}){3})""")
        val SCOPE_NAME = Regex("""onvif://www\.onvif\.org/name/([^\s<]+)""")
        val SCOPE_HARDWARE = Regex("""onvif://www\.onvif\.org/hardware/([^\s<]+)""")
    }
}
