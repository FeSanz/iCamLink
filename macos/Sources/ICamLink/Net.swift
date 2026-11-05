import CryptoKit
import Darwin
import Foundation

// MARK: - Small BSD-socket helpers

enum Sock {
    /// Connects with a timeout; returns the connected fd or nil.
    static func connect(host: String, port: Int, timeoutMs: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { close(fd); return nil }

        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 {
            guard errno == EINPROGRESS else { close(fd); return nil }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&p, 1, Int32(timeoutMs)) > 0 else { close(fd); return nil }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { close(fd); return nil }
        }
        _ = fcntl(fd, F_SETFL, flags)
        return fd
    }

    static func setTimeouts(_ fd: Int32, ms: Int) {
        var tv = timeval(tv_sec: ms / 1000, tv_usec: Int32((ms % 1000) * 1000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func portOpen(_ host: String, _ port: Int, timeoutMs: Int) -> Bool {
        guard let fd = connect(host: host, port: port, timeoutMs: timeoutMs) else { return false }
        close(fd)
        return true
    }
}

// MARK: - RTSP probe

struct ProbeResult {
    let ok: Bool
    let message: String

    static let success = ProbeResult(ok: true, message: "Conexión exitosa: el flujo RTSP responde.")
    static let badCredentials = ProbeResult(ok: false, message: "Usuario o contraseña RTSP incorrectos.")
    static let notFound = ProbeResult(ok: false, message: "La cámara respondió, pero no existe la ruta /stream2.")
    static let unreachable = ProbeResult(ok: false, message: "No se pudo alcanzar la cámara (revisa IP, puerto y red).")
    static func failure(_ d: String) -> ProbeResult { ProbeResult(ok: false, message: "Error: \(d)") }
}

/// Connection test using a bare RTSP DESCRIBE (Digest/Basic) on the sub stream. It tells apart bad
/// credentials from an unreachable host, and the socket is closed right away so it doesn't keep a
/// camera slot busy the way a real player would.
enum RtspProbe {
    static func probe(host: String, port: Int, user: String, pass: String) async -> ProbeResult {
        await Task.detached { probeSync(host: host, port: port, user: user, pass: pass) }.value
    }

    private static func probeSync(host: String, port: Int, user: String, pass: String) -> ProbeResult {
        let uri = "rtsp://\(host):\(port)/stream2"
        guard let first = describe(host, port, uri, nil) else { return .unreachable }
        switch first.code {
        case 200: return .success
        case 404: return .notFound
        case 401:
            guard let auth = authHeader(first.headers, uri, user, pass) else { return .failure("método de autenticación no soportado") }
            guard let second = describe(host, port, uri, auth) else { return .unreachable }
            switch second.code {
            case 200: return .success
            case 401, 403: return .badCredentials
            case 404: return .notFound
            default: return .failure("respuesta RTSP \(second.code)")
            }
        default: return .failure("respuesta RTSP \(first.code)")
        }
    }

    private static func describe(_ host: String, _ port: Int, _ uri: String, _ auth: String?) -> (code: Int, headers: [String])? {
        guard let fd = Sock.connect(host: host, port: port, timeoutMs: 3000) else { return nil }
        defer { close(fd) }
        Sock.setTimeouts(fd, ms: 4000)
        var req = "DESCRIBE \(uri) RTSP/1.0\r\nCSeq: 1\r\nAccept: application/sdp\r\nUser-Agent: iCamLink\r\n"
        if let auth { req += "Authorization: \(auth)\r\n" }
        req += "\r\n"
        let bytes = Array(req.utf8)
        guard send(fd, bytes, bytes.count, 0) == bytes.count else { return nil }

        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 2048)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            data.append(chunk, count: n)
            if data.count > 32_768 { break }
        }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let status = lines.removeFirst().split(separator: " ")
        guard status.count >= 2, let code = Int(status[1]) else { return nil }
        return (code, lines.prefix { !$0.isEmpty }.map { $0 })
    }

    private static func authHeader(_ headers: [String], _ uri: String, _ user: String, _ pass: String) -> String? {
        let challenges = headers
            .filter { $0.lowercased().hasPrefix("www-authenticate:") }
            .map { String($0[$0.index(after: $0.firstIndex(of: ":")!)...]).trimmingCharacters(in: .whitespaces) }

        if let digest = challenges.first(where: { $0.lowercased().hasPrefix("digest") }) {
            let args = String(digest.dropFirst(6))
            var p: [String: String] = [:]
            let re = try! NSRegularExpression(pattern: #"(\w+)=(?:"([^"]*)"|([^,\s]*))"#)
            for m in re.matches(in: args, range: NSRange(args.startIndex..., in: args)) {
                let key = String(args[Range(m.range(at: 1), in: args)!]).lowercased()
                let r = m.range(at: 2).location != NSNotFound ? m.range(at: 2) : m.range(at: 3)
                p[key] = Range(r, in: args).map { String(args[$0]) } ?? ""
            }
            guard let nonce = p["nonce"] else { return nil }
            let realm = p["realm"] ?? ""
            let ha1 = md5("\(user):\(realm):\(pass)")
            let ha2 = md5("DESCRIBE:\(uri)")
            let qop = p["qop"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0 == "auth" }
            let nc = "00000001"
            let cnonce = (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            let response = qop != nil ? md5("\(ha1):\(nonce):\(nc):\(cnonce):\(qop!):\(ha2)") : md5("\(ha1):\(nonce):\(ha2)")
            let header = "Digest username=\"\(user)\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"\(uri)\", response=\"\(response)\""
            return qop != nil ? "\(header), qop=\(qop!), nc=\(nc), cnonce=\"\(cnonce)\"" : header
        }
        if challenges.contains(where: { $0.lowercased().hasPrefix("basic") }) {
            return "Basic " + Data("\(user):\(pass)".utf8).base64EncodedString()
        }
        return nil
    }

    private static func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Discovery

struct DiscoveredCamera: Identifiable, Hashable {
    var host: String
    var name: String?
    /// True when it answered WS-Discovery or has the ONVIF port (2020) open; false = only RTSP (554).
    var onvif: Bool
    var id: String { host }
}

struct NoLocalNetworkError: LocalizedError {
    var errorDescription: String? { "No hay conexión a una red local." }
}

/// Finds ONVIF cameras: a WS-Discovery multicast probe (UDP 3702) runs alongside a /24 sweep for
/// Tapo's ONVIF port (2020) and the RTSP port (554), since some routers block multicast.
final class OnvifDiscovery: @unchecked Sendable {
    private let wsWindowMs = 4000
    private let portTimeoutMs = 600

    private final class Cancel: @unchecked Sendable { var flag = false }
    private let cancel = Cancel()

    func stop() { cancel.flag = true }

    /// Blocking; call from a background thread. `onUpdate` may be called from any thread.
    func scan(onUpdate: @escaping @Sendable ([DiscoveredCamera], Double) -> Void) throws {
        let locals = Self.localAddresses()
        if locals.isEmpty { throw NoLocalNetworkError() }
        cancel.flag = false

        let state = NSLock()
        var found: [String: DiscoveredCamera] = [:]
        var done = 0
        var wsDone = false
        let prefixes = Array(Set(locals.map { $0.split(separator: ".").prefix(3).joined(separator: ".") })).sorted()
        let total = 254 * prefixes.count

        func publish() {
            state.lock()
            let list = found.values.sorted { Self.ipKey($0.host) < Self.ipKey($1.host) }
            let progress = min(1.0, Double(done) / Double(total) * 0.85 + (wsDone ? 0.15 : 0))
            state.unlock()
            onUpdate(list, progress)
        }

        let group = DispatchGroup()
        let wsGroup = DispatchGroup()
        let cancel = cancel

        for ip in locals {
            wsGroup.enter()
            DispatchQueue.global().async {
                self.wsDiscovery(local: ip, cancel: cancel) { host, name in
                    state.lock()
                    let old = found[host]
                    found[host] = DiscoveredCamera(host: host, name: old?.name ?? name, onvif: true)
                    state.unlock()
                    publish()
                }
                wsGroup.leave()
            }
        }
        wsGroup.notify(queue: .global()) { state.lock(); wsDone = true; state.unlock(); publish() }

        let gate = DispatchSemaphore(value: 64)
        let localSet = Set(locals)
        for prefix in prefixes {
            for i in 1...254 {
                let host = "\(prefix).\(i)"
                gate.wait()
                group.enter()
                DispatchQueue.global().async {
                    defer { gate.signal(); group.leave() }
                    if !cancel.flag && !localSet.contains(host) {
                        let onvif = Sock.portOpen(host, 2020, timeoutMs: self.portTimeoutMs)
                        if onvif || Sock.portOpen(host, 554, timeoutMs: self.portTimeoutMs) {
                            state.lock()
                            found[host] = DiscoveredCamera(host: host, name: found[host]?.name, onvif: onvif || (found[host]?.onvif ?? false))
                            state.unlock()
                        }
                    }
                    state.lock(); done += 1; let d = done; state.unlock()
                    if d % 8 == 0 { publish() }
                }
            }
        }
        group.wait()
        wsGroup.wait()
        if cancel.flag { return }
        publish()
    }

    private func wsDiscovery(local: String, cancel: Cancel, onFound: (String, String?) -> Void) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, local, &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return }
        var ifaddr = addr.sin_addr
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &ifaddr, socklen_t(MemoryLayout<in_addr>.size))
        Sock.setTimeouts(fd, ms: 300)

        var group = sockaddr_in()
        group.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        group.sin_family = sa_family_t(AF_INET)
        group.sin_port = in_port_t(3702).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &group.sin_addr)

        let probe = Array(Self.probeXml().utf8)
        let start = Date()
        var lastSend = Date.distantPast
        var buf = [UInt8](repeating: 0, count: 8192)
        while !cancel.flag && Date().timeIntervalSince(start) * 1000 < Double(wsWindowMs) {
            if Date().timeIntervalSince(lastSend) >= 1.5 {
                lastSend = Date()
                _ = withUnsafePointer(to: &group) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, probe, probe.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            if n <= 0 { continue }
            let text = String(decoding: buf[0..<n], as: UTF8.self)
            var senderBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &senderBuf, socklen_t(INET_ADDRSTRLEN))
            let sender = String(cString: senderBuf)
            let host = Self.firstMatch(#"XAddrs>\s*([^<]+)<"#, in: text)
                .flatMap { Self.firstMatch(#"https?://(\d{1,3}(?:\.\d{1,3}){3})"#, in: $0) } ?? sender
            let name = (Self.firstMatch(#"onvif://www\.onvif\.org/name/([^\s<]+)"#, in: text)
                        ?? Self.firstMatch(#"onvif://www\.onvif\.org/hardware/([^\s<]+)"#, in: text))?.removingPercentEncoding
            onFound(host, name)
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// IPv4 addresses of active Ethernet/Wi-Fi style interfaces (en*); VPN/virtual adapters are skipped.
    private static func localAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [String] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  Int32(ifa.ifa_flags) & IFF_UP != 0, Int32(ifa.ifa_flags) & IFF_LOOPBACK == 0,
                  String(cString: ifa.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("169.254.") { out.append(ip) }
            }
        }
        return out
    }

    private static func ipKey(_ ip: String) -> Int {
        ip.split(separator: ".").reduce(0) { $0 * 256 + (Int($1) ?? 0) }
    }

    private static func probeXml() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl"><e:Header><w:MessageID>uuid:\(UUID().uuidString)</w:MessageID><w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To><w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header><e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>
        """
    }
}
