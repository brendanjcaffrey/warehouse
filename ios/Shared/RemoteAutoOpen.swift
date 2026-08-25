/// decides when the watch opens the phone's now playing screen on its own.
/// opening the app while the phone is playing means the remote is what was
/// wanted, but backing out of it says the opposite, & that answer has to
/// stick: the availability that pushed the screen is still true a moment
/// later, so without a latch the pop is undone as fast as it happens
struct RemoteAutoOpen {
    private var hasOpened = false

    /// answers the availability the menu is looking at; true means push the
    /// remote screen
    mutating func shouldOpen(isRemoteAvailable: Bool, isPlayingLocally: Bool) -> Bool {
        guard isRemoteAvailable else {
            // the phone stopped or went out of range; whatever it plays next
            // is a new session & earns another open
            hasOpened = false
            return false
        }
        // a watch already making sound is left alone
        guard !hasOpened, !isPlayingLocally else { return false }
        hasOpened = true
        return true
    }

    /// records a screen the user opened themselves, so the automatic one
    /// doesn't follow it back in
    mutating func noteOpened() {
        hasOpened = true
    }
}
