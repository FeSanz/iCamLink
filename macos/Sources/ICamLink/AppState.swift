import AppKit
import Foundation

enum AppScreen { case viewer, settings }

/// Single source of truth shared by the viewer and settings screens.
@MainActor
final class AppState: ObservableObject {
    private let store = CameraStore()
    private var discovery = OnvifDiscovery()
    private var settings: AppSettings

    @Published private(set) var cameras: [Camera]
    @Published private(set) var selectedId: String?
    @Published private(set) var mode: ViewMode
    @Published private(set) var volume: Int
    @Published private(set) var screen: AppScreen = .viewer
    /// True while the window is minimized/hidden: streams are released so camera slots are freed.
    @Published private(set) var suspended = false

    private var volumeBeforeMute: Int
    private let mini = MiniWindowController()

    private func restoreMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.isMiniaturized { w.deminiaturize(nil) }
    }

    init() {
        settings = store.loadSettings()
        cameras = store.loadCameras()
        selectedId = settings.selectedId
        mode = settings.mode
        let v = min(max(settings.volume, 0), 100)
        volume = v
        volumeBeforeMute = v > 0 ? v : 60

        let nc = NotificationCenter.default
        mini.onExpand = { [weak self] in self?.restoreMainWindow() }
        nc.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, !(n.object is MiniPanel) else { return }
                self.suspended = true
                if let camera = self.selectedCamera { self.mini.show(state: self, camera: camera) }
            }
        }
        nc.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, !(n.object is MiniPanel) else { return }
                self.mini.close()
                self.suspended = false
            }
        }
        nc.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspended = true }
        }
        nc.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspended = false }
        }
    }

    /// Falls back to the first camera when nothing (valid) is selected.
    var selectedCamera: Camera? { cameras.first { $0.id == selectedId } ?? cameras.first }

    func select(_ id: String) { selectedId = id; persist() }

    func focus(on id: String) { selectedId = id; setMode(.focus) }

    func toggleMode() { setMode(mode == .focus ? .grid : .focus) }

    private func setMode(_ m: ViewMode) { mode = m; persist() }

    func setVolume(_ v: Int) {
        volume = min(max(v, 0), 100)
        if volume > 0 { volumeBeforeMute = volume }
        persist()
    }

    func toggleMute() { setVolume(volume == 0 ? volumeBeforeMute : 0) }

    func openSettings() { screen = .settings }

    func closeSettings() {
        stopScan()
        screen = .viewer
    }

    private func persist() {
        settings = AppSettings(selectedId: selectedId, mode: mode, volume: volume)
        store.saveSettings(settings)
    }

    // MARK: cameras

    func upsert(_ camera: Camera) {
        if let i = cameras.firstIndex(where: { $0.id == camera.id }) { cameras[i] = camera } else { cameras.append(camera) }
        store.saveCameras(cameras)
    }

    func delete(_ id: String) {
        cameras.removeAll { $0.id == id }
        store.saveCameras(cameras, removed: [id])
    }

    func move(from: IndexSet, to: Int) {
        cameras.move(fromOffsets: from, toOffset: to)
        store.saveCameras(cameras)
    }

    func isRegistered(_ host: String) -> Bool { cameras.contains { $0.host == host } }

    func addDiscovered(_ selected: [DiscoveredCamera], username: String, password: String) {
        for found in selected where !isRegistered(found.host) {
            cameras.append(Camera.create(name: found.name ?? "Cámara \(cameras.count + 1)", host: found.host,
                                         port: 554, username: username, password: password))
        }
        store.saveCameras(cameras)
    }

    // MARK: network scan

    @Published private(set) var scanning = false
    @Published private(set) var scanProgress = 0.0
    @Published private(set) var scanError: String?
    @Published private(set) var found: [DiscoveredCamera] = []
    private var scanToken = 0

    func startScan() {
        discovery.stop()
        discovery = OnvifDiscovery()
        scanToken += 1
        let token = scanToken
        found = []
        scanError = nil
        scanProgress = 0
        scanning = true
        let discovery = discovery
        Task.detached { [weak self] in
            do {
                try discovery.scan { list, progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.scanToken == token else { return }
                        self.found = list
                        self.scanProgress = progress
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    if self?.scanToken == token { self?.scanError = error.localizedDescription }
                }
            }
            await MainActor.run { [weak self] in
                if self?.scanToken == token { self?.scanning = false }
            }
        }
    }

    func stopScan() {
        discovery.stop()
        scanToken += 1
        scanning = false
    }
}
