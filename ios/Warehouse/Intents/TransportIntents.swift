import AppIntents

/// transport controls conform to audio playback intent so siri & shortcuts
/// can run them without foregrounding the app

struct PauseIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pause"
    static let description = IntentDescription("Pauses playback.")

    @Dependency private var player: PlayerStore

    @MainActor
    func perform() async throws -> some IntentResult {
        guard player.song != nil else {
            throw IntentError.nothingPlaying
        }
        player.pause()
        return .result()
    }
}

struct ResumeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume"
    static let description = IntentDescription("Resumes playback.")

    @Dependency private var player: PlayerStore

    @MainActor
    func perform() async throws -> some IntentResult {
        guard player.song != nil else {
            throw IntentError.nothingPlaying
        }
        player.resume()
        return .result()
    }
}

struct TogglePlayPauseIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Toggles between playing and paused.")

    @Dependency private var player: PlayerStore

    @MainActor
    func perform() async throws -> some IntentResult {
        guard player.song != nil else {
            throw IntentError.nothingPlaying
        }
        player.togglePlayPause()
        return .result()
    }
}

struct SkipToNextIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Skip to Next Song"
    static let description = IntentDescription("Skips to the next song in the queue.")

    @Dependency private var player: PlayerStore

    @MainActor
    func perform() async throws -> some IntentResult {
        guard player.song != nil else {
            throw IntentError.nothingPlaying
        }
        player.skipToNext()
        return .result()
    }
}

struct SkipToPreviousIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Skip to Previous Song"
    static let description = IntentDescription("Goes back to the previous song in the queue.")

    @Dependency private var player: PlayerStore

    @MainActor
    func perform() async throws -> some IntentResult {
        guard player.song != nil else {
            throw IntentError.nothingPlaying
        }
        player.skipToPrevious()
        return .result()
    }
}
