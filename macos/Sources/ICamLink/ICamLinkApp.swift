import SwiftUI

@main
struct ICamLinkApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("iCamLink") {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 760, minHeight: 460)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1280, height: 720)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Configuración…") { state.openSettings() }.keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Cambiar vista") { state.toggleMode() }.keyboardShortcut("g", modifiers: .command)
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        // Swapping the screen removes the old one from the view tree, which releases every stream.
        switch state.screen {
        case .viewer: ViewerView()
        case .settings: SettingsView()
        }
    }
}
