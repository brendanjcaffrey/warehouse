import MusicKit
import AppKit
import Foundation

struct AuthStatus {
    var authorized: Bool
    var error: Optional<String>
}

class MusicAuth {
    static func getStatus(status: MusicAuthorization.Status = MusicAuthorization.currentStatus) -> AuthStatus {
        switch status {
        case .notDetermined:
            return AuthStatus(authorized: false, error: "not determined")
        case .denied:
            return AuthStatus(authorized: false, error: "denied")
        case .restricted:
            return AuthStatus(authorized: false, error: "restricted")
        case .authorized:
            return AuthStatus(authorized: true, error: nil)
        @unknown default:
            fatalError()
        }
    }

    static func request() async -> AuthStatus {
        return Self.getStatus(status: await MusicAuthorization.request())
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media")!
        NSWorkspace.shared.open(url)
    }
}
