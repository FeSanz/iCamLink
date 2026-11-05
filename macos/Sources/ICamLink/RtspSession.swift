import AppKit
import Foundation

enum StreamStatus { case connecting, live, reconnecting }

/// Owns one libvlc player. Decoded frames arrive through libvlc's video callbacks into a malloc'd
/// BGRA buffer and are shown by assigning a CGImage to a CALayer (no child NSView/NSWindow, so
/// overlays and rounded corners work over live video).
final class PlayerCore: @unchecked Sendable {
    struct Snapshot { var playing = false, failed = false; var lastAlive = Date() }

    private static let maxFrameWidth: UInt32 = 1920
    private static let events: [Int32] = [Vlc.evOpening, Vlc.evBuffering, Vlc.evPlaying, Vlc.evEndReached, Vlc.evError, Vlc.evTimeChanged]

    private let vlc = Vlc.shared
    private let lock = NSLock()
    private var buffer: UnsafeMutableRawPointer?
    private var width = 0, height = 0, pitch = 0
    private var renderPending = false
    private var closed = false
    private var player: Vlc.Ptr?
    private var retained: Unmanaged<PlayerCore>?

    private var snap = Snapshot()

    func resetSignals() { lock.lock(); snap = Snapshot(); lock.unlock() }
    func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return snap }
    private func signal(_ type: Int32) {
        lock.lock()
        switch type {
        case Vlc.evPlaying: snap.playing = true; snap.lastAlive = Date()
        case Vlc.evEndReached, Vlc.evError: snap.failed = true
        default: snap.lastAlive = Date()
        }
        lock.unlock()
    }

    /// Set from the main thread by the video view.
    weak var layer: CALayer?

    var isAvailable: Bool { vlc.available }

    func start() {
        guard player == nil, let p = vlc.makePlayer() else { return }
        player = p
        let me = Unmanaged.passRetained(self)
        retained = me
        let opaque = me.toOpaque()
        vlc.setVideoCallbacks(p, lock: Self.onLock, unlock: Self.onUnlock, display: Self.onDisplay,
                              format: Self.onFormat, cleanup: Self.onCleanup, opaque: opaque)
        vlc.attach(p, events: Self.events, cb: Self.onEvent, opaque: opaque)
    }

    func play(url: String, options: [String]) {
        guard let p = player else { return }
        vlc.play(p, url: url, options: options)
    }

    func stopPlayback() { if let p = player { vlc.stop(p) } }

    func applyVolume(_ v: Int) -> Bool {
        guard let p = player else { return false }
        return vlc.setVolume(p, v)
    }

    /// Blocking (waits for the RTSP TEARDOWN): call off the main thread.
    func shutdown() {
        guard let p = player else { return }
        player = nil
        vlc.detach(p, events: Self.events, cb: Self.onEvent, opaque: retained!.toOpaque())
        vlc.stop(p)
        vlc.release(p)
        lock.lock()
        closed = true
        buffer?.deallocate()
        buffer = nil
        lock.unlock()
        retained?.release()
        retained = nil
    }

    // MARK: libvlc callbacks (VLC threads)

    private static let onEvent: Vlc.EventCb = { event, opaque in
        guard let event, let opaque else { return }
        let core = Unmanaged<PlayerCore>.fromOpaque(opaque).takeUnretainedValue()
        core.signal(event.load(as: Int32.self))
    }

    private static let onFormat: Vlc.FormatCb = { opaque, chroma, w, h, pitches, lines in
        guard let opaque, let chroma, let w, let h, let pitches, let lines,
              let raw = opaque.pointee else { return 0 }
        let core = Unmanaged<PlayerCore>.fromOpaque(raw).takeUnretainedValue()
        memcpy(chroma, "RV32", 4) // BGRA, matches the CGImage below

        var nw = w.pointee, nh = h.pointee
        if nw > maxFrameWidth {
            nh = UInt32((Double(nh) * Double(maxFrameWidth) / Double(nw)).rounded())
            nw = maxFrameWidth
        }
        nw &= ~1; nh &= ~1
        w.pointee = nw; h.pointee = nh
        pitches.pointee = nw * 4
        lines.pointee = nh

        core.lock.lock()
        core.buffer?.deallocate()
        core.width = Int(nw); core.height = Int(nh); core.pitch = Int(nw) * 4
        core.buffer = UnsafeMutableRawPointer.allocate(byteCount: core.pitch * core.height, alignment: 16)
        core.lock.unlock()
        return 1
    }

    private static let onCleanup: Vlc.CleanupCb = { _ in }

    private static let onLock: Vlc.LockCb = { opaque, planes in
        let core = Unmanaged<PlayerCore>.fromOpaque(opaque!).takeUnretainedValue()
        core.lock.lock()
        planes!.pointee = core.buffer
        return nil
    }

    private static let onUnlock: Vlc.UnlockCb = { opaque, _, _ in
        Unmanaged<PlayerCore>.fromOpaque(opaque!).takeUnretainedValue().lock.unlock()
    }

    private static let onDisplay: Vlc.DisplayCb = { opaque, _ in
        let core = Unmanaged<PlayerCore>.fromOpaque(opaque!).takeUnretainedValue()
        core.lock.lock()
        let skip = core.renderPending || core.closed
        if !skip { core.renderPending = true }
        core.lock.unlock()
        if skip { return }
        DispatchQueue.main.async { core.render() }
    }

    private func render() {
        lock.lock()
        renderPending = false
        guard !closed, let buffer, width > 0, height > 0 else { lock.unlock(); return }
        let data = Data(bytes: buffer, count: pitch * height) // copy, then release the lock quickly
        let (w, h, p) = (width, height, pitch)
        lock.unlock()

        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: p,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }
}

/// Tapo cameras only accept a handful of simultaneous RTSP clients, so a new session for a camera
/// must never start while the previous one for that same camera is still tearing down.
@MainActor
enum StreamManager {
    private static var teardowns: [String: Task<Void, Never>] = [:]

    static func awaitFree(_ cameraId: String) async { await teardowns[cameraId]?.value }

    static func teardown(_ cameraId: String, _ block: @escaping @Sendable () -> Void) {
        let previous = teardowns[cameraId]
        teardowns[cameraId] = Task.detached {
            await previous?.value
            block()
            try? await Task.sleep(for: .milliseconds(250)) // let the camera free the slot
        }
    }
}

/// One RTSP connection to one camera at one quality, with auto-reconnect.
/// `audio == false` is a muted preview (audio isn't even requested).
@MainActor
final class StreamModel: ObservableObject {
    @Published private(set) var status: StreamStatus = .connecting
    @Published private(set) var unavailable = false

    let core = PlayerCore()
    private let camera: Camera
    private let quality: StreamQuality
    private let audio: Bool
    private var volume = 0
    private var volumeApplied = false
    private var task: Task<Void, Never>?
    private var released = false

    private static let startDebounce = 150
    private static let connectTimeout = 10.0
    private static let stallTimeout = 6.0

    init(camera: Camera, quality: StreamQuality, audio: Bool) {
        self.camera = camera
        self.quality = quality
        self.audio = audio
    }

    func start() {
        guard task == nil, !released else { return }
        guard core.isAvailable else { unavailable = true; return }
        core.start()
        task = Task { await run() }
    }

    func setVolume(_ percent: Int) {
        volume = percent
        volumeApplied = false
        if audio { tryApplyVolume() }
    }

    func release() {
        guard !released else { return }
        released = true
        task?.cancel()
        task = nil
        let core = core
        StreamManager.teardown(camera.id) { core.shutdown() }
    }

    private func run() async {
        try? await Task.sleep(for: .milliseconds(Self.startDebounce)) // rapid selection changes never reach the camera
        await StreamManager.awaitFree(camera.id)
        var attempt = 0
        while !Task.isCancelled {
            status = attempt == 0 ? .connecting : .reconnecting
            volumeApplied = false
            core.resetSignals()
            core.play(url: camera.rtspURL(quality), options: options())

            let began = Date()
            var playing = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                let s = core.snapshot()
                if s.failed { break }
                if s.playing {
                    if !playing { playing = true; attempt = 0 }
                    status = .live
                    if !volumeApplied { tryApplyVolume() }
                    if Date().timeIntervalSince(s.lastAlive) > Self.stallTimeout { break }
                } else if Date().timeIntervalSince(max(began, s.lastAlive)) > Self.connectTimeout {
                    break
                }
            }
            if Task.isCancelled { return }
            let core = core
            await Task.detached { core.stopPlayback() }.value
            attempt += 1
            status = .reconnecting
            try? await Task.sleep(for: .milliseconds(min(1000 * attempt, 8000)))
        }
    }

    private func options() -> [String] {
        var o = [":network-caching=300", ":live-caching=300", ":rtsp-tcp", ":clock-jitter=0", ":clock-synchro=0",
                 ":rtsp-user=\(camera.username)", ":rtsp-pwd=\(camera.password)"]
        if !audio { o.append(":no-audio") }
        return o
    }

    /// libvlc creates the audio output after the Playing event and a volume set before that is lost,
    /// so it is re-applied on every progress signal until the read-back confirms it stuck.
    private func tryApplyVolume() {
        guard audio, !released else { return }
        volumeApplied = core.applyVolume(volume)
    }
}
