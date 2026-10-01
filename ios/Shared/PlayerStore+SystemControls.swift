import AVFoundation
import Foundation
import MediaPlayer
import UIKit

/// what happens when a track finishes: stop at the end of the queue,
/// repeat the whole queue, or repeat the current track
enum RepeatMode: String, Codable, Sendable {
    case off
    case all
    case one

    /// the state after this one when the repeat button is tapped
    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    /// maps from the system now playing controls' repeat setting
    init(_ repeatType: MPRepeatType) {
        switch repeatType {
        case .one: self = .one
        case .all: self = .all
        default: self = .off
        }
    }

    /// maps back into the system now playing controls' repeat setting
    var repeatType: MPRepeatType {
        switch self {
        case .off: .off
        case .all: .all
        case .one: .one
        }
    }
}

/// what the player is doing with the current track beyond playing or paused.
/// the watch fetches tracks on demand, so a tap can mean "downloading" or
/// "not here and no way to get it" rather than an instant start
enum PlaybackStatus: Equatable, Sendable {
    case ready
    /// the file isn't on disk yet & is being fetched before playback starts
    case fetching
    /// the remote item is waiting for enough audio to play
    case buffering
    /// not on disk & the server can't be reached, so there's nothing to play
    case unavailable
    /// watchos only: the audio session wouldn't activate. long form audio has
    /// to go to a bluetooth output there, so this is what no headphones looks
    /// like from here
    case needsOutput
}

extension PlayerStore {
    /// the audio session belongs to the process, not a player instance
    private static var audioSessionConfigured = false

    /// the metadata shown on the lock screen & in control center;
    /// artwork is added separately since it needs the file store
    nonisolated static func baseNowPlayingInfo(for song: Song, duration: TimeInterval) -> [String: Any] {
        var info: [String: Any] = [
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPMediaItemPropertyTitle: song.name,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]
        if !song.artistName.isEmpty {
            info[MPMediaItemPropertyArtist] = song.artistName
        }
        if !song.albumName.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = song.albumName
        }
        return info
    }

    func configureAudioSessionIfNeeded() {
        guard !Self.audioSessionConfigured else { return }
        Self.audioSessionConfigured = true
        let session = AVAudioSession.sharedInstance()
        // long form audio is how watchos routes music to bluetooth headphones,
        // and on ios it puts us in the same route group as the music app: with
        // the default policy an airplay output picked outside the app still
        // gets our audio, but our session keeps reporting the built in speaker,
        // so the route picker in now playing shows the wrong output
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
    }

    /// makes the audio session ready for playback; on watchos activation is
    /// async & prompts the user to pick a bluetooth output, which can be
    /// declined, so playback only starts once it succeeds
    func activateSession() async -> Bool {
        if let activateSessionForTests { return await activateSessionForTests() }
        #if os(watchOS)
        if sessionActivated { return true }
        sessionActivated = (try? await AVAudioSession.sharedInstance().activate(options: [])) ?? false
        return sessionActivated
        #else
        // failures here have never blocked playback on ios, keep it that way
        try? AVAudioSession.sharedInstance().setActive(true)
        return true
        #endif
    }

    /// listens for interruptions (calls, siri, other apps) and route changes
    /// (unplugging headphones) so playback state stays in sync with the system
    func observeAudioSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        }
        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleRouteChange(note) }
        }
    }

    /// the system paused us for a call or siri; reflect that, then resume when
    /// it ends if the interruption says we should
    func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // a track that hasn't started yet has no audio to interrupt, and
            // watchos raises one of these as the audio session activates for a
            // bluetooth output; taking the pending start down with it is what
            // left a finished download sitting at a play button
            guard status != .fetching else { break }
            guard status != .buffering || pendingStartTime == nil else { break }
            pause()
        case .ended:
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:))
            if options?.contains(.shouldResume) == true {
                resume()
            }
        @unknown default:
            break
        }
    }

    /// pause when the headphones are unplugged, matching the system music app
    func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        if reason == .oldDeviceUnavailable {
            #if os(watchOS)
            // the output is gone, so the next play must re-activate & re-route
            sessionActivated = false
            #endif
            pause()
        }
    }

    func configureRemoteCommandsIfNeeded() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipToPrevious() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipToNext() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
        center.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            let shuffled = event.shuffleType != .off
            Task { @MainActor in self?.setShuffled(shuffled) }
            return .success
        }
        center.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            let mode = RepeatMode(event.repeatType)
            Task { @MainActor in self?.setRepeatMode(mode) }
            return .success
        }
        updateRemoteCommandModes()
    }

    /// mirrors shuffle & repeat into the system now playing controls; watchos
    /// takes the commands but has no properties to reflect their state
    func updateRemoteCommandModes() {
        #if !os(watchOS)
        let center = MPRemoteCommandCenter.shared()
        center.changeShuffleModeCommand.currentShuffleType = queue.isShuffled ? .items : .off
        center.changeRepeatModeCommand.currentRepeatType = repeatMode.repeatType
        #endif
    }

    func setNowPlayingInfo(for song: Song) {
        var info = Self.baseNowPlayingInfo(for: song, duration: window.duration)
        artworkFetch?.cancel()
        artworkFetch = nil
        if let filename = song.artworkFilename {
            if fileStore.exists(.artwork, filename) {
                info[MPMediaItemPropertyArtwork] = artwork(filename)
            } else if !downloadedOnly, let fetchArtwork {
                fetchNowPlayingArtwork(filename, using: fetchArtwork)
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func artwork(_ filename: String) -> MPMediaItemArtwork {
        let url = fileStore.fileURL(.artwork, filename)
        let size = CGSize(width: 600, height: 600)
        return MPMediaItemArtwork(boundsSize: size) { _ in
            UIImage(contentsOfFile: url.path) ?? UIImage()
        }
    }

    /// the info above went up without artwork because the file isn't here yet,
    /// so fetch it & fold it in, as long as the same track is still playing
    private func fetchNowPlayingArtwork(
        _ filename: String, using fetch: @escaping @MainActor (String) async -> Bool
    ) {
        let generation = startGeneration
        artworkFetch = Task { @MainActor in
            let downloaded = await fetch(filename)
            guard downloaded, !Task.isCancelled, generation == startGeneration,
                  song?.artworkFilename == filename,
                  var info = MPNowPlayingInfoCenter.default().nowPlayingInfo
            else { return }
            info[MPMediaItemPropertyArtwork] = artwork(filename)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    func updateNowPlayingPlaybackState() {
        let center = MPNowPlayingInfoCenter.default()
        guard var info = center.nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isActuallyPlaying ? 1.0 : 0.0
        center.nowPlayingInfo = info
    }
}
