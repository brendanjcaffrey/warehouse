import AppIntents

/// the zero-setup siri phrases; every phrase must mention the app by name,
/// and the system allows at most 10 app shortcuts per app
struct WarehouseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PauseIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Pause the music in \(.applicationName)"
            ],
            shortTitle: "Pause",
            systemImageName: "pause.fill")
        AppShortcut(
            intent: ResumeIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Resume the music in \(.applicationName)"
            ],
            shortTitle: "Resume",
            systemImageName: "play.fill")
        AppShortcut(
            intent: SkipToNextIntent(),
            phrases: [
                "Skip this song in \(.applicationName)",
                "Play the next song in \(.applicationName)"
            ],
            shortTitle: "Next Song",
            systemImageName: "forward.fill")
        AppShortcut(
            intent: SkipToPreviousIntent(),
            phrases: [
                "Go back a song in \(.applicationName)",
                "Play the previous song in \(.applicationName)"
            ],
            shortTitle: "Previous Song",
            systemImageName: "backward.fill")
        AppShortcut(
            intent: PlaySongIntent(),
            phrases: [
                "Play the song \(\.$song) in \(.applicationName)",
                "Play \(\.$song) in \(.applicationName)"
            ],
            shortTitle: "Play Song",
            systemImageName: "music.note")
        AppShortcut(
            intent: PlayAlbumIntent(),
            phrases: [
                "Play the album \(\.$album) in \(.applicationName)",
                "Play \(\.$album) in \(.applicationName)"
            ],
            shortTitle: "Play Album",
            systemImageName: "square.stack")
        AppShortcut(
            intent: PlayArtistIntent(),
            phrases: [
                "Play songs by \(\.$artist) in \(.applicationName)",
                "Play \(\.$artist) in \(.applicationName)"
            ],
            shortTitle: "Play Artist",
            systemImageName: "music.microphone")
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "Play the playlist \(\.$playlist) in \(.applicationName)",
                "Play \(\.$playlist) in \(.applicationName)"
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list")
        AppShortcut(
            intent: PlayLibraryShuffledIntent(),
            phrases: [
                "Shuffle my library in \(.applicationName)",
                "Shuffle \(.applicationName)"
            ],
            shortTitle: "Shuffle Library",
            systemImageName: "shuffle")
    }
}
