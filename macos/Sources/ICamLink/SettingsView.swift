import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var editing: EditorTarget?
    @State private var selected: Set<String> = []
    @State private var scanUser = "admin"
    @State private var scanPass = ""
    @State private var scanTest: ProbeResult?
    @State private var scanTesting = false
    @State private var showScan = false

    struct EditorTarget: Identifiable {
        let id = UUID()
        var camera: Camera?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if showScan { scanPanel }
                    camerasList
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.bg)
        .sheet(item: $editing) { target in
            CameraEditor(camera: target.camera) { cam in
                state.upsert(cam)
                editing = nil
            } onCancel: { editing = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            IconButton(systemName: "chevron.left", tint: Theme.text, help: "Volver (Esc)") { state.closeSettings() }
                .keyboardShortcut(.cancelAction)
            Text("Configuración").font(.system(size: 20, weight: .semibold))
            Spacer()
            Button {
                showScan = true
                if !state.scanning { state.startScan() }
            } label: { Label("Escanear red local", systemImage: "magnifyingglass") }
                .buttonStyle(AccentButtonStyle())
            Button { editing = EditorTarget(camera: nil) } label: { Label("Agregar manualmente", systemImage: "plus") }
                .buttonStyle(OutlineButtonStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    // MARK: cameras

    private var camerasList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CÁMARAS").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            if state.cameras.isEmpty {
                Text("Escanea la red o agrega una cámara manualmente.").foregroundStyle(Theme.muted).padding(.vertical, 12)
            } else {
                List {
                    ForEach(state.cameras) { cam in
                        HStack(spacing: 12) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(Theme.muted).help("Arrastrar para reordenar")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cam.name).lineLimit(1)
                                Text("\(cam.host):\(cam.port)").font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            IconButton(systemName: "pencil", tint: Theme.muted, help: "Editar") { editing = EditorTarget(camera: cam) }
                            IconButton(systemName: "trash", tint: Theme.danger, help: "Eliminar") { state.delete(cam.id) }
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Theme.surface)
                    }
                    .onMove { state.move(from: $0, to: $1) }
                }
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(height: CGFloat(state.cameras.count) * 56 + 8)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: scan

    private var scanPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("RED LOCAL").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                Spacer()
                Button("Cerrar") { state.stopScan(); showScan = false }.buttonStyle(.plain).foregroundStyle(Theme.muted)
            }
            if state.scanning {
                ProgressView(value: state.scanProgress).tint(Theme.accent)
                Text("Buscando cámaras…").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            if let err = state.scanError { Text(err).foregroundStyle(Theme.danger) }
            if !state.scanning && state.found.isEmpty && state.scanError == nil {
                Text("No se encontraron cámaras.").foregroundStyle(Theme.muted)
            }
            ForEach(state.found) { f in
                let registered = state.isRegistered(f.host)
                HStack {
                    Toggle("", isOn: Binding(
                        get: { selected.contains(f.host) },
                        set: { if $0 { selected.insert(f.host) } else { selected.remove(f.host) } }))
                        .labelsHidden().disabled(registered)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.name ?? (f.onvif ? "Cámara ONVIF" : "Dispositivo RTSP"))
                        Text(f.host).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Text(registered ? "Ya agregada" : (f.onvif ? "ONVIF" : "RTSP"))
                        .font(.system(size: 12)).foregroundStyle(registered ? Theme.live : Theme.muted)
                }
            }
            if !state.found.isEmpty {
                Divider().overlay(Theme.border)
                HStack(spacing: 12) {
                    labeled("Usuario RTSP") { TextField("", text: $scanUser).textFieldStyle(.roundedBorder) }
                    labeled("Contraseña RTSP") { SecureField("", text: $scanPass).textFieldStyle(.roundedBorder) }
                }
                HStack {
                    Button(scanTesting ? "Probando…" : "Probar") { Task { await testScan() } }
                        .buttonStyle(OutlineButtonStyle()).disabled(scanTesting || selected.isEmpty)
                    Button("Agregar seleccionadas") {
                        state.addDiscovered(state.found.filter { selected.contains($0.host) }, username: scanUser, password: scanPass)
                        selected = []
                        scanTest = nil
                    }
                    .buttonStyle(AccentButtonStyle()).disabled(selected.isEmpty)
                    if let r = scanTest { Text(r.message).font(.system(size: 12)).foregroundStyle(r.ok ? Theme.live : Theme.danger) }
                }
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func testScan() async {
        guard let host = state.found.first(where: { selected.contains($0.host) })?.host else { return }
        scanTesting = true
        scanTest = await RtspProbe.probe(host: host, port: 554, user: scanUser, pass: scanPass)
        scanTesting = false
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            content()
        }
    }
}

/// Add/edit form, shown as a sheet.
struct CameraEditor: View {
    let camera: Camera?
    let onSave: (Camera) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var host = ""
    @State private var port = "554"
    @State private var user = "admin"
    @State private var pass = ""
    @State private var result: ProbeResult?
    @State private var testing = false

    private var portValue: Int? { Int(port).flatMap { (1...65535).contains($0) ? $0 : nil } }
    private var valid: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty && portValue != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(camera == nil ? "Agregar cámara" : "Editar cámara").font(.system(size: 18, weight: .semibold))
            field("Nombre personalizado") { TextField("Ej. Entrada", text: $name) }
            HStack(spacing: 12) {
                field("Dirección IP") { TextField("192.168.1.50", text: $host) }
                field("Puerto RTSP") { TextField("554", text: $port).frame(width: 90) }
            }
            HStack(spacing: 12) {
                field("Usuario RTSP") { TextField("", text: $user) }
                field("Contraseña RTSP") { SecureField("", text: $pass) }
            }
            HStack {
                Button(testing ? "Probando…" : "Probar conexión") { Task { await test() } }
                    .buttonStyle(OutlineButtonStyle()).disabled(!valid || testing)
                if let r = result { Text(r.message).font(.system(size: 12)).foregroundStyle(r.ok ? Theme.live : Theme.danger) }
                Spacer()
                Button("Cancelar", action: onCancel).buttonStyle(.plain).foregroundStyle(Theme.muted).keyboardShortcut(.cancelAction)
                Button("Guardar") { save() }.buttonStyle(AccentButtonStyle()).disabled(!valid).keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 480)
        .background(Theme.bg)
        .onAppear {
            if let c = camera { name = c.name; host = c.host; port = String(c.port); user = c.username; pass = c.password }
        }
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            content()
        }
    }

    private func test() async {
        guard let p = portValue else { return }
        testing = true
        result = await RtspProbe.probe(host: host.trimmingCharacters(in: .whitespaces), port: p, user: user, pass: pass)
        testing = false
    }

    private func save() {
        guard let p = portValue else { return }
        let h = host.trimmingCharacters(in: .whitespaces)
        let n = name.trimmingCharacters(in: .whitespaces)
        onSave(Camera(id: camera?.id ?? UUID().uuidString, name: n.isEmpty ? h : n, host: h, port: p, username: user, password: pass))
    }
}
