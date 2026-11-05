import AppKit
import SwiftUI

/// Picture-in-picture: while the main window is minimized, a small always-on-top panel keeps the
/// last selected camera (HD stream, with audio) visible over other applications. Drag it from its
/// body, resize from its edges (fixed 16:9). Restoring the main window closes it.
final class MiniPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MiniWindowController {
    private var panel: MiniPanel?
    private let frameKey = "miniFrame"
    var onExpand: (() -> Void)?

    var isShown: Bool { panel != nil }

    func show(state: AppState, camera: Camera) {
        guard panel == nil else { return }
        let p = MiniPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                          styleMask: [.borderless, .resizable],
                          backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.contentAspectRatio = NSSize(width: 16, height: 9)
        p.contentMinSize = NSSize(width: 240, height: 135)

        let view = MiniView(camera: camera, onExpand: { [weak self] in self?.onExpand?() }, onClose: { [weak self] in self?.close() })
            .environmentObject(state)
            .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: view)
        host.wantsLayer = true
        host.layer?.cornerRadius = 8
        host.layer?.masksToBounds = true
        p.contentView = host

        place(p)
        p.orderFrontRegardless()
        panel = p
    }

    func close() {
        guard let p = panel else { return }
        UserDefaults.standard.set(NSStringFromRect(p.frame), forKey: frameKey)
        panel = nil
        p.orderOut(nil)
        p.contentView = nil // releases the stream
    }

    /// Restores the last frame if it is still on a screen, else the bottom-right of the main screen.
    private func place(_ p: NSPanel) {
        if let s = UserDefaults.standard.string(forKey: frameKey) {
            let r = NSRectFromString(s)
            if r.width >= 240, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) {
                p.setFrame(r, display: false)
                return
            }
        }
        let area = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let w: CGFloat = 320, h: CGFloat = 180
        p.setFrame(NSRect(x: area.maxX - w - 16, y: area.minY + 16, width: w, height: h), display: false)
    }
}

private struct MiniView: View {
    @EnvironmentObject var state: AppState
    let camera: Camera
    let onExpand: () -> Void
    let onClose: () -> Void
    @State private var hover = false

    var body: some View {
        ZStack {
            CameraView(camera: camera, quality: .main, volume: state.volume)
                .id("\(camera.id)|\(camera.host)|\(camera.port)|\(camera.username)|\(camera.password)")
                .allowsHitTesting(false)
            if hover {
                VStack {
                    Text(camera.name).font(.system(size: 11)).foregroundStyle(.white).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Theme.scrim, in: Capsule())
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                    HStack(spacing: 2) {
                        IconButton(systemName: state.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                   help: "Silenciar") { state.toggleMute() }
                        Slider(value: Binding(get: { Double(state.volume) }, set: { state.setVolume(Int($0)) }), in: 0...100)
                            .tint(Theme.accent).controlSize(.small)
                        IconButton(systemName: "arrow.up.left.and.arrow.down.right", help: "Abrir iCamLink", action: onExpand)
                        IconButton(systemName: "xmark", help: "Cerrar", action: onClose)
                    }
                    .padding(.horizontal, 6)
                    .background(Theme.scrim, in: Capsule())
                }
                .padding(8)
                .transition(.opacity)
            }
        }
        .background(Color.black)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}
