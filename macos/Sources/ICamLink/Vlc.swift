import Foundation

/// Minimal libvlc binding loaded with dlopen, so the project builds with just the Command Line Tools.
/// The bundled copy (Contents/Frameworks) is preferred; /Applications/VLC.app is the development fallback.
final class Vlc: @unchecked Sendable {
    static let shared = Vlc()

    typealias Ptr = OpaquePointer
    typealias EventCb = @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void
    typealias LockCb = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UnsafeMutableRawPointer?
    typealias UnlockCb = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafePointer<UnsafeMutableRawPointer?>?) -> Void
    typealias DisplayCb = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    typealias FormatCb = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?, UnsafeMutablePointer<CChar>?,
                                         UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?,
                                         UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> UInt32
    typealias CleanupCb = @convention(c) (UnsafeMutableRawPointer?) -> Void

    // libvlc_event_e values (libvlc 3.x)
    static let evOpening: Int32 = 0x102
    static let evBuffering: Int32 = 0x103
    static let evPlaying: Int32 = 0x104
    static let evEndReached: Int32 = 0x109
    static let evError: Int32 = 0x10a
    static let evTimeChanged: Int32 = 0x10b

    private(set) var available = false
    private(set) var instance: Ptr?

    private var mediaNewLocation: (@convention(c) (Ptr, UnsafePointer<CChar>) -> Ptr?)!
    private var mediaAddOption: (@convention(c) (Ptr, UnsafePointer<CChar>) -> Void)!
    private var mediaRelease: (@convention(c) (Ptr) -> Void)!
    private var playerNew: (@convention(c) (Ptr) -> Ptr?)!
    private var playerSetMedia: (@convention(c) (Ptr, Ptr?) -> Void)!
    private var playerPlay: (@convention(c) (Ptr) -> Int32)!
    private var playerStop: (@convention(c) (Ptr) -> Void)!
    private var playerRelease: (@convention(c) (Ptr) -> Void)!
    private var videoSetCallbacks: (@convention(c) (Ptr, LockCb?, UnlockCb?, DisplayCb?, UnsafeMutableRawPointer?) -> Void)!
    private var videoSetFormatCallbacks: (@convention(c) (Ptr, FormatCb?, CleanupCb?) -> Void)!
    private var audioSetVolume: (@convention(c) (Ptr, Int32) -> Int32)!
    private var audioGetVolume: (@convention(c) (Ptr) -> Int32)!
    private var eventManager: (@convention(c) (Ptr) -> Ptr?)!
    private var eventAttach: (@convention(c) (Ptr, Int32, EventCb, UnsafeMutableRawPointer?) -> Int32)!
    private var eventDetach: (@convention(c) (Ptr, Int32, EventCb, UnsafeMutableRawPointer?) -> Void)!

    private init() {
        guard let (lib, plugins) = Self.locate(), let h = dlopen(lib, RTLD_NOW | RTLD_LOCAL) else { return }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }
        guard
            let new = sym("libvlc_new", (@convention(c) (Int32, UnsafePointer<UnsafePointer<CChar>?>?) -> Ptr?).self),
            let a = sym("libvlc_media_new_location", (@convention(c) (Ptr, UnsafePointer<CChar>) -> Ptr?).self),
            let b = sym("libvlc_media_add_option", (@convention(c) (Ptr, UnsafePointer<CChar>) -> Void).self),
            let c = sym("libvlc_media_release", (@convention(c) (Ptr) -> Void).self),
            let d = sym("libvlc_media_player_new", (@convention(c) (Ptr) -> Ptr?).self),
            let e = sym("libvlc_media_player_set_media", (@convention(c) (Ptr, Ptr?) -> Void).self),
            let f = sym("libvlc_media_player_play", (@convention(c) (Ptr) -> Int32).self),
            let g = sym("libvlc_media_player_stop", (@convention(c) (Ptr) -> Void).self),
            let i = sym("libvlc_media_player_release", (@convention(c) (Ptr) -> Void).self),
            let j = sym("libvlc_video_set_callbacks", (@convention(c) (Ptr, LockCb?, UnlockCb?, DisplayCb?, UnsafeMutableRawPointer?) -> Void).self),
            let k = sym("libvlc_video_set_format_callbacks", (@convention(c) (Ptr, FormatCb?, CleanupCb?) -> Void).self),
            let l = sym("libvlc_audio_set_volume", (@convention(c) (Ptr, Int32) -> Int32).self),
            let m = sym("libvlc_audio_get_volume", (@convention(c) (Ptr) -> Int32).self),
            let n = sym("libvlc_media_player_event_manager", (@convention(c) (Ptr) -> Ptr?).self),
            let o = sym("libvlc_event_attach", (@convention(c) (Ptr, Int32, EventCb, UnsafeMutableRawPointer?) -> Int32).self),
            let p = sym("libvlc_event_detach", (@convention(c) (Ptr, Int32, EventCb, UnsafeMutableRawPointer?) -> Void).self)
        else { return }
        mediaNewLocation = a; mediaAddOption = b; mediaRelease = c; playerNew = d; playerSetMedia = e
        playerPlay = f; playerStop = g; playerRelease = i; videoSetCallbacks = j; videoSetFormatCallbacks = k
        audioSetVolume = l; audioGetVolume = m; eventManager = n; eventAttach = o; eventDetach = p

        setenv("VLC_PLUGIN_PATH", plugins, 1)
        let args = ["--no-stats", "--drop-late-frames", "--skip-frames", "--no-osd", "--no-video-title-show"]
        let cArgs = args.map { strdup($0) }
        defer { cArgs.forEach { free($0) } }
        var ptrs: [UnsafePointer<CChar>?] = cArgs.map { UnsafePointer($0) }
        instance = new(Int32(ptrs.count), &ptrs)
        available = instance != nil
    }

    private static func locate() -> (lib: String, plugins: String)? {
        let fm = FileManager.default
        var candidates: [(String, String)] = []
        if let fw = Bundle.main.privateFrameworksPath, let res = Bundle.main.resourcePath {
            candidates.append((fw + "/libvlc.dylib", res + "/vlc/plugins"))
        }
        let vlc = "/Applications/VLC.app/Contents/MacOS"
        candidates.append((vlc + "/lib/libvlc.dylib", vlc + "/plugins"))
        return candidates.first { fm.fileExists(atPath: $0.0) && fm.fileExists(atPath: $0.1) }
    }

    // MARK: Wrappers

    func makePlayer() -> Ptr? { instance.flatMap { playerNew($0) } }

    func play(_ player: Ptr, url: String, options: [String]) {
        guard let inst = instance, let media = url.withCString({ mediaNewLocation(inst, $0) }) else { return }
        for o in options { o.withCString { mediaAddOption(media, $0) } }
        playerSetMedia(player, media)
        mediaRelease(media) // the player keeps its own reference
        _ = playerPlay(player)
    }

    func stop(_ player: Ptr) { playerStop(player) }
    func release(_ player: Ptr) { playerRelease(player) }

    func setVideoCallbacks(_ player: Ptr, lock: LockCb, unlock: UnlockCb, display: DisplayCb,
                           format: FormatCb, cleanup: CleanupCb, opaque: UnsafeMutableRawPointer) {
        videoSetFormatCallbacks(player, format, cleanup)
        videoSetCallbacks(player, lock, unlock, display, opaque)
    }

    func setVolume(_ player: Ptr, _ v: Int) -> Bool {
        _ = audioSetVolume(player, Int32(v))
        return audioGetVolume(player) == Int32(v)
    }

    func attach(_ player: Ptr, events: [Int32], cb: EventCb, opaque: UnsafeMutableRawPointer) {
        guard let em = eventManager(player) else { return }
        for e in events { _ = eventAttach(em, e, cb, opaque) }
    }

    func detach(_ player: Ptr, events: [Int32], cb: EventCb, opaque: UnsafeMutableRawPointer) {
        guard let em = eventManager(player) else { return }
        for e in events { eventDetach(em, e, cb, opaque) }
    }
}
