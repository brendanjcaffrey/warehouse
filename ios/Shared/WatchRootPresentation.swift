/// browsing readiness and playback destinations for the watch's root screen.
struct WatchRootPresentation {
    let libraryState: WatchLibraryStore.State
    let showsLocalNowPlaying: Bool
    let showsRemoteNowPlaying: Bool

    var showsLibraryMenu: Bool { libraryState == .ready }

    init(libraryState: WatchLibraryStore.State, hasLocalTrack: Bool, isRemoteAvailable: Bool) {
        self.libraryState = libraryState
        showsLocalNowPlaying = hasLocalTrack
        showsRemoteNowPlaying = isRemoteAvailable
    }
}
