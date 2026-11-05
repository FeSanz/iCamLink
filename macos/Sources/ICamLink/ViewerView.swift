import SwiftUI

struct ViewerView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack {
            Theme.bg
            if state.cameras.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "video.slash").font(.system(size: 44)).foregroundStyle(Theme.muted)
                    Text("No hay cámaras registradas").font(.system(size: 16))
                    Button("Agregar cámaras") { state.openSettings() }.buttonStyle(AccentButtonStyle())
                }
            } else if state.suspended {
                Color.clear // a minimized window shows nothing; streams are released
            } else if state.mode == .focus {
                FocusLayout()
            } else {
                GridLayout()
            }

            HStack(spacing: 0) {
                IconButton(systemName: state.mode == .focus ? "square.grid.2x2" : "rectangle.inset.filled",
                           help: state.mode == .focus ? "Ver cuadrícula" : "Ver una cámara") { state.toggleMode() }
                IconButton(systemName: "gearshape", help: "Configuración (⌘,)") { state.openSettings() }
            }
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(Theme.scrim, in: Capsule())
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .opacity(state.cameras.isEmpty ? 0 : 1)
        }
    }
}

private struct FocusLayout: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let main = state.selectedCamera
        HStack(spacing: 0) {
            ScrollView {
                // Lazy: rows scrolled away are removed, which frees their stream.
                LazyVStack(spacing: 8) {
                    ForEach(state.cameras) { cam in
                        Thumb(camera: cam, isMain: cam.id == main?.id)
                            .frame(width: 184, height: 104)
                            .onTapGesture { state.select(cam.id) }
                    }
                }
                .padding(.leading, 8).padding(.top, 8)
                .padding(.trailing, 8)
            }
            .frame(width: 208)
            .background(Theme.surface)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }

            ZStack {
                if let main {
                    CameraView(camera: main, quality: .main, volume: state.volume)
                        .id("\(main.id)|\(main.host)|\(main.port)|\(main.username)|\(main.password)")
                    Text(main.name)
                        .font(.system(size: 12)).foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Theme.scrim, in: RoundedRectangle(cornerRadius: 6))
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .allowsHitTesting(false)
                    VolumeBar()
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
        }
    }
}

private struct Thumb: View {
    let camera: Camera
    let isMain: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if isMain {
                // The camera already streams in HD in the main view; a second connection would waste a slot.
                Theme.accentContainer
                Text("En vista principal").font(.system(size: 11)).foregroundStyle(Theme.accentSoft)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CameraView(camera: camera, quality: .sub, volume: nil)
                    .id("\(camera.id)|\(camera.host)|\(camera.port)|\(camera.username)|\(camera.password)")
            }
            Text(camera.name)
                .font(.system(size: 11)).foregroundStyle(.white).lineLimit(1)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Theme.scrim, in: RoundedRectangle(cornerRadius: 6))
                .padding(5).frame(maxWidth: 150, alignment: .leading)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isMain ? Theme.accent : Theme.border, lineWidth: isMain ? 2 : 1))
        .contentShape(Rectangle())
    }
}

private struct VolumeBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 4) {
            IconButton(systemName: state.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       help: state.volume == 0 ? "Activar sonido" : "Silenciar") { state.toggleMute() }
            Slider(value: Binding(get: { Double(state.volume) }, set: { state.setVolume(Int($0)) }), in: 0...100)
                .tint(Theme.accent)
                .frame(width: 140)
                .padding(.trailing, 10)
        }
        .padding(.leading, 4).padding(.vertical, 2)
        .background(Theme.scrim, in: Capsule())
    }
}

private struct GridLayout: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        GeometryReader { geo in
            let (cols, rows) = Self.bestGrid(count: state.cameras.count, width: geo.size.width, height: geo.size.height)
            let spacing: CGFloat = 4
            let cellW = (geo.size.width - spacing * CGFloat(cols + 1)) / CGFloat(cols)
            let cellH = (geo.size.height - spacing * CGFloat(rows + 1)) / CGFloat(rows)
            VStack(spacing: spacing) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: spacing) {
                        ForEach(0..<cols, id: \.self) { c in
                            let i = r * cols + c
                            if i < state.cameras.count {
                                let cam = state.cameras[i]
                                ZStack(alignment: .bottomLeading) {
                                    CameraView(camera: cam, quality: .sub, volume: nil)
                                        .id("\(cam.id)|\(cam.host)|\(cam.port)|\(cam.username)|\(cam.password)")
                                    Text(cam.name)
                                        .font(.system(size: 11)).foregroundStyle(.white).lineLimit(1)
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(Theme.scrim, in: RoundedRectangle(cornerRadius: 6))
                                        .padding(6).allowsHitTesting(false)
                                }
                                .frame(width: max(cellW, 1), height: max(cellH, 1))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                                .onTapGesture { state.focus(on: cam.id) }
                            } else {
                                Color.clear.frame(width: max(cellW, 1), height: max(cellH, 1))
                            }
                        }
                    }
                }
            }
            .padding(spacing)
        }
    }

    /// Picks the cols×rows layout whose 16:9 cells come out largest (3→2x2, 4→2x2, 6→3x2, ...).
    static func bestGrid(count: Int, width: CGFloat, height: CGFloat) -> (Int, Int) {
        var best = (1, max(count, 1))
        var bestSize: CGFloat = 0
        for cols in 1...max(count, 1) {
            let rows = Int((Double(count) / Double(cols)).rounded(.up))
            let size = min(width / CGFloat(cols), height / CGFloat(rows) * 16 / 9)
            if size > bestSize * 0.999 { bestSize = size; best = (cols, rows) }
        }
        return best
    }
}
