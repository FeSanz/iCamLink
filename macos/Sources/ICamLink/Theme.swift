import SwiftUI

enum Theme {
    static let bg = Color(hex: 0x11151F)
    static let surface = Color(hex: 0x1C253A)
    static let surfaceAlt = Color(hex: 0x26324D)
    static let field = Color(hex: 0x161D2E)
    static let border = Color(hex: 0x2B3650)
    static let text = Color(hex: 0xEEF2FB)
    static let muted = Color(hex: 0x9FADC9)
    static let accent = Color(hex: 0xE8782B)
    static let accentSoft = Color(hex: 0xFFD9BF)
    static let accentContainer = Color(hex: 0x3A2A22)
    static let scrim = Color.black.opacity(0.55)
    static let live = Color(hex: 0x2ECC71)
    static let warn = Color(hex: 0xFFC107)
    static let danger = Color(hex: 0xDC3545)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(hex: 0x11151F))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
    }
}

struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .overlay(Capsule().stroke(Theme.border))
            .background(configuration.isPressed ? Theme.surfaceAlt : .clear, in: Capsule())
    }
}

struct IconButton: View {
    let systemName: String
    var tint: Color = .white
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 14)).foregroundStyle(tint).frame(width: 32, height: 32).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
