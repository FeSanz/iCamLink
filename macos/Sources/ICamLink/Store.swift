import Foundation
import Security

/// Cameras live in ~/Library/Application Support/iCamLink/cameras.json; each password is kept in the
/// login Keychain (the macOS counterpart of the DPAPI protection used on Windows). UI preferences
/// go to a separate plain settings.json.
final class CameraStore {
    private struct StoredCamera: Codable {
        var id, name, host: String
        var port: Int
        var username: String
    }

    private let dir: URL
    private static let service = "com.icamlink.mac.camera"

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("iCamLink", isDirectory: true)
    }

    private var camerasURL: URL { dir.appendingPathComponent("cameras.json") }
    private var settingsURL: URL { dir.appendingPathComponent("settings.json") }

    func loadCameras() -> [Camera] {
        guard let data = try? Data(contentsOf: camerasURL),
              let stored = try? JSONDecoder().decode([StoredCamera].self, from: data) else { return [] }
        return stored.map {
            Camera(id: $0.id, name: $0.name, host: $0.host, port: $0.port, username: $0.username,
                   password: Self.readPassword($0.id) ?? "")
        }
    }

    func saveCameras(_ cameras: [Camera], removed: [String] = []) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stored = cameras.map { StoredCamera(id: $0.id, name: $0.name, host: $0.host, port: $0.port, username: $0.username) }
        if let data = try? JSONEncoder().encode(stored) { try? data.write(to: camerasURL, options: .atomic) }
        for c in cameras { Self.writePassword(c.password, for: c.id) }
        for id in removed { Self.deletePassword(id) }
    }

    func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func saveSettings(_ settings: AppSettings) {
        // Preferences are best-effort; failing to persist them must never take the UI down.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(settings) { try? data.write(to: settingsURL, options: .atomic) }
    }

    // MARK: Keychain

    private static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }

    private static func readPassword(_ id: String) -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writePassword(_ password: String, for id: String) {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(id)
            q[kSecValueData as String] = data
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    private static func deletePassword(_ id: String) { SecItemDelete(query(id) as CFDictionary) }
}
