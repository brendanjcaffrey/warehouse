/// decides when the watch opens the phone's now playing screen on its own.
/// opening the app while the phone is playing means the remote is what was
/// wanted, but backing out of it says the opposite, & that answer has to
/// stick: the availability that pushed the screen is still true a moment
/// later, so without a latch the pop is undone as fast as it happens
struct RemoteAutoOpen {
    private var hasOpened = false

    /// opens only for observed phone playback; a pause or stall keeps the
    /// user's choice to leave the remote screen for this phone session
    mutating func shouldOpen(isRemoteAvailable: Bool, isRemotePlaying: Bool, isPlayingLocally: Bool) -> Bool {
        guard isRemoteAvailable else {
            // the phone has no track or went out of range; a later phone
            // session earns another open
            hasOpened = false
            return false
        }
        // a watch already making sound is left alone
        guard isRemotePlaying, !hasOpened, !isPlayingLocally else { return false }
        hasOpened = true
        return true
    }

    /// records a screen the user opened themselves, so the automatic one
    /// doesn't follow it back in
    mutating func noteOpened() {
        hasOpened = true
    }
}
