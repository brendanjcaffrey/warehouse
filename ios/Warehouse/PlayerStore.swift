import AVFoundation
import Foundation
import MediaPlayer
import Observation
import UIKit

/// what happens when a track finishes: stop at the end of the queue,
/// repeat the whole queue, or repeat the current track
enum RepeatMode: Sendable {
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
}

@MainActor
@Observable
final class PlayerStore {
    private(set) var queue = PlayQueue(songs: [])
    private(set) var isPlaying = false
    private(set) var repeatMode: RepeatMode = .off
    private(set) var window = PlaybackWindow()
    /// the playhead position within the file, not the window
    private(set) var currentTime: TimeInterval = 0

    var song: Song? { queue.current?.song }

    private let fileStore: FileStore
    private let updates: UpdatesStore
    private let downloader: FileDownloader
    private let player = AVPlayer()
    /// kept from the last play call for loading later tracks in the queue
    private var token: String?
    private var baseURL: URL?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var audioSessionConfigured = false
    private var remoteCommandsConfigured = false
    /// set when the user scrubs past the stop time, so the track plays
    /// through to the end of the file instead of stopping right away
    private var ignoresFinish = false
    /// seeks the player hasn't finished yet; the time observer stays quiet
    /// until they land so the playhead doesn't flick back to the old position
    private var pendingSeeks = 0
    /// bumped every time a new track starts, so a download that finishes after
    /// the user has moved on doesn't hijack playback
    private var startGeneration = 0

    init(fileStore: FileStore, updates: UpdatesStore, client: LibraryClient = LibraryClient()) {
        self.fileStore = fileStore
        self.updates = updates
        self.downloader = FileDownloader(client: client, fileStore: fileStore)
        observeAudioSession()
    }

    /// starts playing songs in order, positioned at the tapped one so previous
    /// walks back through the earlier tracks; replaces the current queue and
    /// turns repeat off
    func play(_ songs: [Song], startingAt index: Int = 0, token: String?, baseURL: URL?) {
        start(PlayQueue(songs: songs, startingAt: index), repeating: .off, token: token, baseURL: baseURL)
    }

    /// starts playing songs in a random order; replaces the current queue and
    /// repeats it once it runs out
    func playShuffled(_ songs: [Song], token: String?, baseURL: URL?) {
        start(PlayQueue(shuffling: songs), repeating: .all, token: token, baseURL: baseURL)
    }

    private func start(_ newQueue: PlayQueue, repeating mode: RepeatMode, token: String?, baseURL: URL?) {
        guard newQueue.current != nil else { return }
        repeatMode = mode
        self.token = token
        self.baseURL = baseURL
        var replacement = newQueue
        replacement.inheritHistory(from: queue)
        queue = replacement
        startCurrent()
    }

    /// plays the queue's current track, downloading it from the server first
    /// when it isn't already on disk
    private func startCurrent() {
        guard let song else { return }
        startGeneration += 1
        let generation = startGeneration

        let isDownloaded = fileStore.exists(.music, song.musicFilename)
        // without the file or a way to fetch it there's nothing to play
        guard isDownloaded || (token != nil && baseURL != nil) else {
            player.pause()
            isPlaying = false
            return
        }

        configureAudioSessionIfNeeded()
        configureRemoteCommandsIfNeeded()

        window = PlaybackWindow(duration: song.duration, start: song.start, finish: song.finish)
        currentTime = window.start
        ignoresFinish = false
        isPlaying = true
        setNowPlayingInfo(for: song)
        updateNowPlayingPlaybackState()

        if isDownloaded {
            beginPlayback(of: song)
        } else if let token, let baseURL {
            Task { @MainActor in
                let ok = await downloader.download(.music, filename: song.musicFilename, token: token, baseURL: baseURL)
                // drop it if the user skipped to another track while downloading
                guard generation == startGeneration else { return }
                if ok {
                    beginPlayback(of: song)
                } else {
                    isPlaying = false
                    updateNowPlayingPlaybackState()
                }
            }
        }
    }

    /// swaps the downloaded file into the player and starts it, unless the user
    /// paused while it was still downloading
    private func beginPlayback(of song: Song) {
        let item = AVPlayerItem(url: fileStore.fileURL(.music, song.musicFilename))
        observeEnd(of: item)
        observeTimeIfNeeded()

        player.replaceCurrentItem(with: item)
        applyStopTime()
        if window.start > 0 {
            seekPlayer(to: window.start)
        }
        if isPlaying {
            player.play()
        }
        updateNowPlayingPlaybackState()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func pause() {
        guard song != nil, isPlaying else { return }
        player.pause()
        isPlaying = false
        updateNowPlayingPlaybackState()
    }

    func resume() {
        guard song != nil, !isPlaying else { return }
        // the session may have gone inactive after a long pause or interruption
        try? AVAudioSession.sharedInstance().setActive(true)
        // play again after the track ended restarts it
        if effectiveEnd > 0 && currentTime >= effectiveEnd {
            seek(to: window.start)
        }
        player.play()
        isPlaying = true
        updateNowPlayingPlaybackState()
    }

    /// steps back through the queue, wrapping around at the start, when near
    /// the beginning of the current track; otherwise restarts it
    func skipToPrevious() {
        guard song != nil else { return }
        if currentTime - window.start <= 3, queue.goBack() {
            startCurrent()
        } else {
            seek(to: window.start)
        }
    }

    /// steps forward through the queue; repeat all wraps around at the end,
    /// otherwise playback stops once past the last track
    func skipToNext() {
        guard song != nil else { return }
        if queue.advance(wrapping: repeatMode == .all) {
            startCurrent()
        } else {
            stop()
        }
    }

    /// queues a song right after the current track, or just plays it when
    /// nothing is queued
    func playNext(_ song: Song, token: String?, baseURL: URL?) {
        if queue.current == nil {
            play([song], token: token, baseURL: baseURL)
        } else {
            queue.playNext(song)
        }
    }

    /// jumps ahead to an upcoming track picked in the queue view
    func playFromUpcoming(at index: Int) {
        guard queue.jump(toUpcomingIndex: index) else { return }
        startCurrent()
    }

    /// plays a track picked from the history: queues it right after the current
    /// track like play next, then jumps straight to it
    func playFromHistory(_ song: Song) {
        guard queue.current != nil else { return }
        queue.playNext(song)
        queue.jump(toUpcomingIndex: 0)
        startCurrent()
    }

    /// picks up a metadata edit: refreshes the queue's copies of the track,
    /// & when it's the one playing also the playback window & lock screen info
    func trackUpdated(_ song: Song) {
        let current = self.song
        queue.updateSong(song)
        guard let current, current.id == song.id else { return }

        // only rebuild the window when the edit moved the markers, so a name
        // edit can't re-arm a stop time the user scrubbed past
        if current.start != song.start || current.finish != song.finish {
            window = PlaybackWindow(duration: song.duration, start: song.start, finish: song.finish)
            ignoresFinish = false
            applyStopTime()
        }
        setNowPlayingInfo(for: song)
        updateNowPlayingPlaybackState()
    }

    /// shuffles the upcoming tracks or restores their original order
    func setShuffled(_ shuffled: Bool) {
        queue.setShuffled(shuffled)
    }

    /// steps the repeat button through off, repeat all & repeat one
    func cycleRepeatMode() {
        repeatMode = repeatMode.next
    }

    /// reorders the upcoming tracks from the queue view
    func moveUpcoming(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        queue.moveUpcoming(fromOffsets: offsets, toOffset: destination)
    }

    func seek(to time: TimeInterval) {
        guard song != nil else { return }
        currentTime = min(max(0, time), window.duration)
        ignoresFinish = window.stopsEarly && currentTime >= window.end
        seekPlayer(to: currentTime)
        updateNowPlayingPlaybackState()
    }

    private func seekPlayer(to time: TimeInterval) {
        pendingSeeks += 1
        // clear the stop time until the seek lands: arming it while the
        // player is still past it would fire the end notification right away
        player.currentItem?.forwardPlaybackEndTime = .invalid
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingSeeks -= 1
                if self.pendingSeeks == 0 {
                    self.applyStopTime()
                }
            }
        }
    }

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

    /// where playback will stop: the track's stop time normally, or the end
    /// of the file once the user scrubs past the stop time
    private var effectiveEnd: TimeInterval {
        window.stopsEarly && !ignoresFinish ? window.end : window.duration
    }

    private func applyStopTime() {
        guard let item = player.currentItem else { return }
        if window.stopsEarly && !ignoresFinish {
            item.forwardPlaybackEndTime = CMTime(seconds: window.end, preferredTimescale: 600)
        } else {
            item.forwardPlaybackEndTime = .invalid
        }
    }

    private func configureAudioSessionIfNeeded() {
        guard !audioSessionConfigured else { return }
        audioSessionConfigured = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    /// listens for interruptions (calls, siri, other apps) and route changes
    /// (unplugging headphones) so playback state stays in sync with the system
    private func observeAudioSession() {
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
            pause()
        }
    }

    private func configureRemoteCommandsIfNeeded() {
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
    }

    private func setNowPlayingInfo(for song: Song) {
        var info = Self.baseNowPlayingInfo(for: song, duration: window.duration)
        if let filename = song.artworkFilename, fileStore.exists(.artwork, filename) {
            let url = fileStore.fileURL(.artwork, filename)
            let size = CGSize(width: 600, height: 600)
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: size) { _ in
                UIImage(contentsOfFile: url.path) ?? UIImage()
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingPlaybackState() {
        let center = MPNowPlayingInfoCenter.default()
        guard var info = center.nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        center.nowPlayingInfo = info
    }

    private func observeTimeIfNeeded() {
        guard timeObserver == nil else { return }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.song != nil, self.pendingSeeks == 0 else { return }
                self.currentTime = min(max(0, time.seconds), self.window.duration)
            }
        }
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        // this fires at forwardPlaybackEndTime too, so custom stop times are respected
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleTrackEnd()
            }
        }
    }

    /// a track played through to its finish: count a play, then repeat it,
    /// move on, or stop depending on the repeat mode & queue position
    func handleTrackEnd() {
        if let song {
            let updates = updates
            Task { await updates.addPlay(trackId: song.id) }
        }
        let continues: Bool
        switch repeatMode {
        case .one:
            continues = queue.repeatCurrent()
        case .all:
            continues = queue.advance(wrapping: true)
        case .off:
            continues = queue.advance()
        }
        if continues {
            startCurrent()
        } else {
            stop()
        }
    }

    /// halts playback at the end of the queue, leaving the last track current
    private func stop() {
        player.pause()
        isPlaying = false
        currentTime = effectiveEnd
        updateNowPlayingPlaybackState()
    }
}
