import AppKit
import Combine

enum MusicAutomationStatus: Equatable {
    case checking
    case authorized
    case notDetermined
    case denied
    case musicNotRunning
    case failed(Int32)

    init(code: Int32) {
        switch code {
        case 0: self = .authorized
        case -1744: self = .notDetermined
        case -1743: self = .denied
        case -600: self = .musicNotRunning
        default: self = .failed(code)
        }
    }

    var message: String {
        switch self {
        case .checking: return "Checking Music automation access…"
        case .authorized: return "Music automation access granted."
        case .notDetermined: return "Music automation access has not been requested."
        case .denied: return "Music automation access denied. Enable it in System Settings."
        case .musicNotRunning: return "Open Music to check automation access."
        case .failed(let code): return "Unable to check Music automation access (error \(code))."
        }
    }

    var canRequest: Bool {
        switch self {
        case .notDetermined, .failed: return true
        default: return false
        }
    }
}

@MainActor
final class MusicAutomationAuthorization: ObservableObject {
    @Published private(set) var status: MusicAutomationStatus = .checking
    @Published private(set) var isChecking = false
    private let check: @MainActor (Bool) async -> Int32

    init(check: @escaping @MainActor (Bool) async -> Int32 = { prompt in
        // permission prompts can block; keep the apple-event check off the main actor.
        await Task.detached {
            NativeMusicTextSource.authorizationStatus(prompt: prompt)
        }.value
    }) {
        self.check = check
    }

    func refresh() async {
        await update(prompt: false)
    }

    func request() async {
        await update(prompt: true)
    }

    private func update(prompt: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        status = MusicAutomationStatus(code: await check(prompt))
    }

    func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        NSWorkspace.shared.open(url)
    }
}
