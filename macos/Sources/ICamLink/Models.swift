import Foundation

/// Tapo exposes the HD feed on /stream1 and a low-resolution feed on /stream2.
enum StreamQuality: String, Codable { case main, sub }

enum ViewMode: String, Codable { case focus, grid }

struct Camera: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var host: String
    var port: Int
    var username: String
    var password: String

    static func create(name: String, host: String, port: Int, username: String, password: String) -> Camera {
        Camera(id: UUID().uuidString, name: name, host: host, port: port, username: username, password: password)
    }

    /// Credentials are passed to libvlc as options, never embedded in the URL (special characters).
    func rtspURL(_ quality: StreamQuality) -> String {
        "rtsp://\(host):\(port)/\(quality == .main ? "stream1" : "stream2")"
    }
}

struct AppSettings: Codable {
    var selectedId: String?
    var mode: ViewMode = .focus
    var volume: Int = 60
}
