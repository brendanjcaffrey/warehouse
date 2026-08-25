import Foundation
import Observation

/// watch-side view of what the phone is playing, plus the commands sent back.
/// the watch is a standalone player most of the time, but when the music is
/// coming out of the phone this is what the app shows instead of starting a
/// second stream of its own
@MainActor
@Observable
final class WatchRemoteStore {
    /// what the phone last said it was playing; nil when it said nothing was,
    /// or when it has never said anything
    private(set) var nowPlaying: RemotePlaybackPayload?
    /// whether the phone can be reached right now, which is what decides if a
    /// command would land
    private(set) var isReachable = false

    /// whether the remote screen is worth showing: the phone has a track & is
    /// close enough to take commands
    var isAvailable: Bool { isReachable && nowPlaying != nil }

    private let send: (RemoteCommand) -> Void

    init(send: @escaping (RemoteCommand) -> Void) {
        self.send = send
    }

    func apply(_ message: WatchRemoteMessage) {
        // commands only travel the other way; nothing here answers them
        guard case .nowPlaying(let payload) = message else { return }
        nowPlaying = payload
    }

    func setReachable(_ reachable: Bool) {
        // only on a change: a failed send reports reachability back through
        // here, & re-asking on every one of those would spin
        guard reachable != isReachable else { return }
        isReachable = reachable
        // a phone that just came back may have started, stopped or changed
        // track while we couldn't hear it
        if reachable {
            send(.requestState)
        }
    }

    /// asks the phone what it is playing; the watch app coming to the front is
    /// the moment its screen has to be right
    func requestState() {
        send(.requestState)
    }

    /// sends a transport command, moving the local copy first so the button
    /// answers the tap rather than the round trip. the phone's push corrects
    /// it a moment later if it disagreed
    func command(_ command: RemoteCommand) {
        switch command {
        case .playPause:
            update { $0.with(isPlaying: !$0.isPlaying) }
        case .pause:
            update { $0.with(isPlaying: false) }
        case .toggleShuffle:
            update { $0.with(isShuffled: !$0.isShuffled) }
        case .cycleRepeat:
            update { $0.with(repeatMode: $0.repeatMode.next) }
        case .next, .previous, .requestState:
            // the track that lands is the phone's to say
            break
        }
        send(command)
    }

    /// tells the phone to stop because the watch is about to make sound of its
    /// own; two players over one pair of headphones is never what was meant
    func pausePhone() {
        guard nowPlaying?.isPlaying == true else { return }
        command(.pause)
    }

    private func update(_ transform: (RemotePlaybackPayload) -> RemotePlaybackPayload) {
        guard let nowPlaying else { return }
        self.nowPlaying = transform(nowPlaying)
    }
}

extension RemotePlaybackPayload {
    /// a copy with one thing changed, for the watch's optimistic updates
    func with(isPlaying: Bool? = nil, isShuffled: Bool? = nil, repeatMode: RepeatMode? = nil)
        -> RemotePlaybackPayload {
        RemotePlaybackPayload(
            trackId: trackId,
            name: name,
            artistName: artistName,
            artworkFilename: artworkFilename,
            isPlaying: isPlaying ?? self.isPlaying,
            isShuffled: isShuffled ?? self.isShuffled,
            repeatMode: repeatMode ?? self.repeatMode)
    }
}
