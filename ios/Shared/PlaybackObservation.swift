import AVFoundation

/// item readiness, buffer prediction, available audio and transport state are separate signals.
struct PlaybackObservationState: Equatable {
    var itemStatus: AVPlayerItem.Status
    var likelyToKeepUp: Bool
    var timeControlStatus: AVPlayer.TimeControlStatus
    var hasBufferedAudio: Bool
    var hasPlaybackProgress: Bool
    var failureReason = "unknown"
}

/// owns the platform observations for one current item. callers cancel when it changes.
@MainActor
enum PlaybackObservation {
    typealias Handler = @MainActor (PlaybackObservationState) -> Void
    typealias Start = @MainActor (AVQueuePlayer, AVPlayerItem, @escaping Handler) -> () -> Void

    static func start(player: AVQueuePlayer, item: AVPlayerItem, receive: @escaping Handler) -> () -> Void {
        let progress = PlaybackProgress(at: item.currentTime().seconds)
        // read all values together on the actor, so queued notifications cannot
        // replay an older buffer prediction over a newer transport state.
        let report: @Sendable (String?, Bool) -> Void = { [weak player, weak item] failure, jumped in
            guard let player, let item else { return }
            Task { @MainActor in
                let time = item.currentTime()
                let buffered = hasBufferedAudio(at: time, ranges: item.loadedTimeRanges.map(\.timeRangeValue))
                if jumped { progress.reset(at: time.seconds) }
                let state = PlaybackObservationState(
                    itemStatus: failure == nil ? item.status : .failed,
                    likelyToKeepUp: item.isPlaybackLikelyToKeepUp,
                    timeControlStatus: player.timeControlStatus,
                    hasBufferedAudio: buffered,
                    hasPlaybackProgress: progress.update(
                        at: time.seconds, playing: player.timeControlStatus == .playing && buffered),
                    failureReason: failure ?? item.error?.localizedDescription ?? "unknown")
                guard state != progress.lastReportedState else { return }
                progress.lastReportedState = state
                receive(state)
            }
        }
        let observations = [
            item.observe(\.status, options: [.initial, .new]) { item, _ in
                // preserve a terminal failure even if the daemon removes the item.
                report(item.status == .failed ? item.error?.localizedDescription ?? "unknown" : nil, false)
            },
            item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { _, _ in report(nil, false) },
            item.observe(\.loadedTimeRanges, options: [.new]) { _, _ in report(nil, false) },
            player.observe(\.timeControlStatus, options: [.new]) { _, _ in report(nil, false) }
        ]
        // mp3 playback can claim to be playing while the media clock remains
        // frozen at the seek target. its first tick is the rendering signal.
        let clock = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { _ in report(nil, false) }
        let jump = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification, object: item, queue: .main
        ) { _ in report(nil, true) }
        return {
            observations.forEach { $0.invalidate() }
            player.removeTimeObserver(clock)
            NotificationCenter.default.removeObserver(jump)
        }
    }

    /// after a remote seek, transport can report playing with an empty range
    /// at the requested offset. only bytes covering the playhead can make audio.
    nonisolated static func hasBufferedAudio(at time: CMTime, ranges: [CMTimeRange]) -> Bool {
        let position = time.seconds
        guard position.isFinite else { return false }
        return ranges.contains { range in
            let start = range.start.seconds
            let end = range.end.seconds
            return start.isFinite && end.isFinite && start <= position && position < end
        }
    }
}

@MainActor
private final class PlaybackProgress {
    var lastReportedState: PlaybackObservationState?
    private var anchor: Double
    private var advanced = false

    init(at time: Double) { anchor = time }

    func reset(at time: Double) {
        anchor = time
        advanced = false
    }

    func update(at time: Double, playing: Bool) -> Bool {
        if !playing || !time.isFinite || !anchor.isFinite || time < anchor {
            reset(at: time)
        } else if time > anchor + 0.01 {
            advanced = true
        }
        return advanced
    }
}
