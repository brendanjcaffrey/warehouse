import Foundation
import ScriptingBridge
import ApplicationServices

final class MusicAutomationErrors: NSObject, SBApplicationDelegate {
    private var failure: Error?

    func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? {
        if failure == nil { failure = error }
        return nil
    }

    func checked<Result>(_ read: () -> Result) throws -> Result {
        failure = nil
        let result = read()
        if let failure { throw Self.failureMessage((failure as NSError).code) }
        return result
    }

    static func failureMessage(_ code: Int) -> MusicTextError {
        switch code {
        case -1743, -1744:
            return MusicTextError(message: "music automation not authorized (\(code)); open rake export:setup and allow music automation; check system settings > privacy & security > automation")
        case -1712:
            return MusicTextError(message: "music automation timed out (-1712); retry when music is responsive")
        default:
            return MusicTextError(message: "music automation failed (\(code))")
        }
    }
}

final class NativeMusicTextSource: MusicTextSource {
    private let music: SBApplication
    private let errors = MusicAutomationErrors()
    private let tracks: SBElementArray
    private var lyricTracks: SBElementArray

    static func authorizationStatus(prompt: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Music")
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, prompt)
    }

    static func authorize(prompt: Bool) throws {
        let status = authorizationStatus(prompt: prompt)
        if status != noErr { throw MusicAutomationErrors.failureMessage(Int(status)) }
    }

    init(allowPrompt: Bool) throws {
        try Self.authorize(prompt: allowPrompt)
        guard let application = SBApplication(bundleIdentifier: "com.apple.Music") else {
            throw MusicTextError(message: "music automation unavailable")
        }
        music = application
        let checker = errors
        application.delegate = checker
        // scriptingbridge uses apple-event ticks (60 per second).
        application.timeout = 60 * 120
        guard let playlists = try checker.checked({ application.value(forKey: "libraryPlaylists") }) as? SBElementArray,
              try checker.checked({ playlists.count }) == 1,
              let playlist = playlists.object(at: 0) as? SBObject,
              let collection = try checker.checked({ playlist.value(forKey: "fileTracks") }) as? SBElementArray else {
            throw MusicTextError(message: "music file-track library unavailable")
        }
        tracks = collection
        lyricTracks = collection
    }

    func excludeLyricsKinds(_ kinds: Set<String>) throws {
        if kinds.isEmpty {
            lyricTracks = tracks
            return
        }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: kinds.sorted().map {
            NSPredicate(format: "kind != %@", $0)
        })
        // preserve the lazy music collection; swift array filtering fetches tracks individually.
        guard let filtered = try errors.checked({
            tracks.perform(NSSelectorFromString("filteredArrayUsingPredicate:"), with: predicate)?.takeUnretainedValue()
        }) as? SBElementArray else {
            throw MusicTextError(message: "music lyrics filter did not return a lazy element array")
        }
        lyricTracks = filtered
    }

    func strings(_ property: String, lyricsOnly: Bool) throws -> [Any] {
        let collection = lyricsOnly ? lyricTracks : tracks
        return try errors.checked { collection.array(byApplying: NSSelectorFromString(property)) }
    }

    func fileTrackCount() throws -> Int {
        try errors.checked { tracks.count }
    }
}
