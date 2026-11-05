import AppKit
import SwiftUI

/// Layer-backed view that shows the frames pushed by a PlayerCore.
private struct VideoLayerView: NSViewRepresentable {
    let core: PlayerCore

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        v.layer?.contentsGravity = .resizeAspect
        v.layer?.masksToBounds = true
        core.layer = v.layer
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) { core.layer = nsView.layer }
}

/// Plays one camera at one quality. Leaving the view tree (deselected, scrolled out, mode switch,
/// window minimized) stops and releases the player so its RTSP slot is freed.
/// `volume == nil` means a muted preview (audio isn't even requested). Callers give the view an
/// `.id(...)` that changes with camera/quality/audio so a new stream is built when those change.
struct CameraView: View {
    let camera: Camera
    let quality: StreamQuality
    let volume: Int?

    @StateObject private var model: StreamModel

    init(camera: Camera, quality: StreamQuality, volume: Int?) {
        self.camera = camera
        self.quality = quality
        self.volume = volume
        _model = StateObject(wrappedValue: StreamModel(camera: camera, quality: quality, audio: volume != nil))
    }

    var body: some View {
        ZStack {
            Color.black
            VideoLayerView(core: model.core)
            if model.unavailable {
                Text("libvlc no disponible").font(.system(size: 12)).foregroundStyle(Theme.warn)
            } else if model.status != .live {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).tint(Theme.accentSoft)
                    Text(model.status == .reconnecting ? "Reconectando…" : "Conectando…")
                        .font(.system(size: 11))
                        .foregroundStyle(model.status == .reconnecting ? Theme.warn : Theme.accentSoft)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Theme.scrim, in: Capsule())
            }
        }
        .onAppear {
            model.setVolume(volume ?? 0)
            model.start()
        }
        .onDisappear { model.release() }
        .onChange(of: volume) { _, new in model.setVolume(new ?? 0) }
    }
}
