import AVFoundation
import Foundation
import MediaPlayer
import Observation
import OSLog
import UIKit

private let log = Logger(subsystem: "com.jcaffrey.warehouse", category: "player")

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
    /// not on disk & the server can't be reached, so there's nothing to play
    case unavailable
    /// watchos only: the audio session wouldn't activate. long form audio has
    /// to go to a bluetooth output there, so this is what no headphones looks
    /// like from here
    case needsOutput
}

@MainActor
@Observable
final class PlayerStore {
    private(set) var queue = PlayQueue(songs: [])
    private(set) var isPlaying = false
    private(set) var repeatMode: RepeatMode = .off
    private(set) var status: PlaybackStatus = .ready
    private(set) var window = PlaybackWindow()
    /// the playhead position within the file, not the window
    private(set) var currentTime: TimeInterval = 0

    var song: Song? { queue.current?.song }
    /// whether a track is loaded & playable right now. exposed for the tests:
    /// an unavailable track has to leave nothing behind of the previous one,
    /// & the player's item is the only place that shows
    var hasLoadedTrack: Bool { player.currentItem != nil }

    private let fileStore: FileStore
    /// the watch bounds what it keeps & passes one in; the phone mirrors the
    /// whole library, so there is nothing to evict and it leaves this nil
    private let fileCache: FileCache?
    /// pulls an artwork file that isn't on disk, for the now playing info. the
    /// watch fetches artwork on demand & wires this to its fetcher; the phone
    /// mirrors the library and leaves it nil
    private let fetchArtwork: (@MainActor (String) async -> Bool)?
    /// called with the track id when a track plays through to its finish; the
    /// phone records a play to push back into itunes, the watch leaves it nil
    private let onTrackPlayed: (@MainActor (String) -> Void)?
    private let downloader: FileDownloader
    private let player = AVPlayer()
    /// kept from the last play call for loading later tracks in the queue
    private var token: String?
    private var baseURL: URL?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    /// watches whether the current item actually loaded, which avfoundation
    /// reports nowhere else
    private var itemStatusObserver: NSKeyValueObservation?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var audioSessionConfigured = false
    private var remoteCommandsConfigured = false
    /// on watchos the session activates asynchronously (it can prompt for a
    /// bluetooth output) & needs re-activating after the route goes away
    private var sessionActivated = false
    /// set when the user scrubs past the stop time, so the track plays
    /// through to the end of the file instead of stopping right away
    private var ignoresFinish = false
    /// seeks the player hasn't finished yet; the time observer stays quiet
    /// until they land so the playhead doesn't flick back to the old position
    private var pendingSeeks = 0
    /// bumped every time a new track starts, so a download that finishes after
    /// the user has moved on doesn't hijack playback
    private var startGeneration = 0
    /// the fetch running ahead of the current track, kept by name so starting
    /// that very track can join it instead of racing a second download of the
    /// same file
    private var prefetch: (filename: String, task: Task<Bool, Never>)?
    /// the second attempt at a prefetch that missed, waiting out the rest of
    /// its delay
    private var prefetchRetry: Task<Void, Never>?
    /// whether this track has already spent its one prefetch retry, so a miss
    /// on a dead link can't turn into a loop
    private var prefetchRetried = false
    /// the now playing artwork being fetched for the current track, cancelled
    /// when another track starts
    private var artworkFetch: Task<Void, Never>?
    /// how long a failed fetch waits before its one retry
    private let retryDelay: TimeInterval
    /// how far into the track a missed prefetch waits before trying again;
    /// long enough to be a different moment on the network, short enough to
    /// still land before the track it's for
    private let prefetchRetryDelay: TimeInterval
    /// tracks that couldn't be fetched since the last one that started; past
    /// the limit the network is plainly gone & skipping on through the queue
    /// at a request timeout apiece is worse than stopping
    private var consecutiveFailures = 0
    /// tracks whose file arrived but wouldn't load, counted apart from the
    /// fetch failures above: the fetch succeeds every time in that case, so
    /// the budget it resets on a successful fetch would never open
    private var consecutiveItemFailures = 0
    private static let failureLimit = 3
    /// stands in for the platform's audio session activation, so tests can
    /// reproduce the watch refusing to activate without a bluetooth output
    private let activateSessionForTests: (@MainActor () async -> Bool)?

    // the retry delay & activation parameters are here for tests
    init(
        fileStore: FileStore,
        client: LibraryClient = LibraryClient(),
        fileCache: FileCache? = nil,
        fetchArtwork: (@MainActor (String) async -> Bool)? = nil,
        onTrackPlayed: (@MainActor (String) -> Void)? = nil,
        retryDelay: TimeInterval = 1,
        prefetchRetryDelay: TimeInterval = 30,
        activateSessionForTests: (@MainActor () async -> Bool)? = nil
    ) {
        self.fileStore = fileStore
        self.fileCache = fileCache
        self.fetchArtwork = fetchArtwork
        self.onTrackPlayed = onTrackPlayed
        self.retryDelay = retryDelay
        self.prefetchRetryDelay = prefetchRetryDelay
        self.activateSessionForTests = activateSessionForTests
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
        // a queue the user just picked starts with a clean slate; whatever the
        // last one couldn't fetch or load shouldn't count against it
        consecutiveFailures = 0
        consecutiveItemFailures = 0
        repeatMode = mode
        self.token = token
        self.baseURL = baseURL
        var replacement = newQueue
        replacement.inheritHistory(from: queue)
        queue = replacement
        updateRemoteCommandModes()
        startCurrent()
    }

    /// plays the queue's current track, downloading it from the server first
    /// when it isn't already on disk
    private func startCurrent() {
        guard let song else { return }
        startGeneration += 1
        let generation = startGeneration
        // the retry budget is per track start, not per session
        prefetchRetried = false

        let isDownloaded = fileStore.exists(.music, song.musicFilename)
        // a prefetch already running for this very track is the fetch we're
        // about to need, so let it finish; anything else has been superseded
        if prefetch?.filename != song.musicFilename {
            cancelPrefetch()
        }
        // hold the file against eviction before anything else touches disk,
        // and release the track we just moved off
        refreshInUse()
        // without the file or a way to fetch it there's nothing to play
        guard isDownloaded || (token != nil && baseURL != nil) else {
            markNotLoaded(.unavailable)
            return
        }

        configureAudioSessionIfNeeded()
        configureRemoteCommandsIfNeeded()

        window = PlaybackWindow(duration: song.duration, start: song.start, finish: song.finish)
        currentTime = window.start
        ignoresFinish = false
        isPlaying = true
        // isPlaying goes up optimistically, so an uncached track on a slow
        // link needs this to tell the ui it's downloading, not stuck
        status = isDownloaded ? .ready : .fetching
        setNowPlayingInfo(for: song)
        updateNowPlayingPlaybackState()

        let token = token
        let baseURL = baseURL
        Task { @MainActor in
            let activated = await activateSession()
            // drop it if the user skipped to another track in the meantime
            guard generation == startGeneration else { return }
            guard activated else {
                // this track never loaded, so say so & take the last one's
                // item down with it rather than looking ready to play
                markNotLoaded(.needsOutput)
                return
            }
            if isDownloaded {
                fileCache?.recordUse(.music, song.musicFilename)
                beginPlayback(of: song)
            } else if let token, let baseURL {
                let ok = await fetchMusic(
                    song.musicFilename, token: token, baseURL: baseURL, generation: generation)
                guard generation == startGeneration else { return }
                if ok {
                    fileCache?.recordUse(.music, song.musicFilename)
                    // a fetch is the only thing that grows the cache on this
                    // side, so it is where the budget gets checked; the
                    // artwork fetcher runs a pass of its own for the browse
                    // path, which the player never sees
                    fileCache?.evict()
                    beginPlayback(of: song)
                } else {
                    handleFailedFetch()
                }
            }
        }
    }

    /// a track we couldn't get shouldn't end the session the way a scratched
    /// track doesn't end the album, so move on to the next one instead
    private func handleFailedFetch() {
        // counted before the skip: this is what stops an offline queue from
        // walking every one of its entries a request timeout at a time
        consecutiveFailures += 1
        // settle here once the network is plainly gone, & when the user paused
        // during the download, since starting something else on their behalf
        // isn't what pause means
        guard consecutiveFailures < Self.failureLimit, isPlaying else {
            markNotLoaded(.unavailable)
            return
        }
        // the same queue rules as the next button: repeat all wraps around,
        // the end of a queue that doesn't repeat is the end
        if queue.advance(wrapping: repeatMode == .all) {
            startCurrent()
        } else {
            markNotLoaded(.unavailable)
        }
    }

    /// the current track didn't start, so drop the item the last one left in
    /// the player: it is fully loaded & seekable, so a stray play() would
    /// resume the wrong audio under this track's title, and its finish would
    /// report a play for a track that never started
    private func markNotLoaded(_ reason: PlaybackStatus) {
        player.pause()
        removeEndObserver()
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        status = reason
        updateNowPlayingPlaybackState()
    }

    /// swaps the downloaded file into the player and starts it, unless the user
    /// paused while it was still downloading
    private func beginPlayback(of song: Song) {
        // something is playing again, so whatever was skipped to get here
        // doesn't count toward giving up on the queue
        consecutiveFailures = 0
        let item = AVPlayerItem(url: fileStore.fileURL(.music, song.musicFilename))
        observeEnd(of: item)
        observeStatus(of: item)
        observeTimeIfNeeded()

        player.replaceCurrentItem(with: item)
        applyStopTime()
        if window.start > 0 {
            seekPlayer(to: window.start)
        }
        if isPlaying {
            player.play()
        }
        status = .ready
        updateNowPlayingPlaybackState()
        // the gap between tracks is only hidden if the next one is already
        // here, so start it now rather than when the current track ends
        prefetchNext()
    }

    /// downloads a track, joining the prefetch already running for it rather
    /// than racing a second download of the same file. a failure earns one
    /// retry: the funnel is derp-relayed with fairness throttling, so one bad
    /// hop says very little about the next
    private func fetchMusic(
        _ filename: String, token: String, baseURL: URL, generation: Int
    ) async -> Bool {
        if let prefetch, prefetch.filename == filename {
            // a prefetch that fails clears itself, so the retry below goes out
            // fresh rather than joining a finished task for the same answer
            if await prefetch.task.value { return true }
        } else if await downloader.download(.music, filename: filename, token: token, baseURL: baseURL) {
            return true
        }
        // a moment between the attempts so a blip has a chance to clear
        try? await Task.sleep(for: .seconds(retryDelay))
        // the user moved on while we waited, so this track isn't wanted now
        guard generation == startGeneration else { return false }
        return await downloader.download(.music, filename: filename, token: token, baseURL: baseURL)
    }

    /// fetches the track after this one while the current one is playing.
    /// failures are silent: the track falls back to being fetched when it's
    /// actually reached & nothing about the playing track changes.
    ///
    /// safe to call at any point — the queue is re-read every time — so the
    /// watch re-arms it when it comes back to the foreground, where transfers
    /// aren't throttled, rather than living with the one shot it gets as a
    /// track starts
    func prefetchNext() {
        let filename = nextPrefetchFilename
        // whatever is outstanding is for a track that isn't next any more
        if let prefetch, prefetch.filename != filename {
            cancelPrefetch()
        }
        guard let filename, let token, let baseURL else { return }
        // already here, or already on its way: restarting a transfer in flight
        // would throw away its progress on exactly the slow link that makes
        // prefetching worth doing
        guard !fileStore.exists(.music, filename), prefetch == nil else { return }

        let generation = startGeneration
        prefetch = (filename, Task { @MainActor in
            let ok = await downloader.download(.music, filename: filename, token: token, baseURL: baseURL)
            guard !Task.isCancelled else { return ok }
            guard ok else {
                // a finished task hands the same answer to everything that
                // joins it, so a failure left in place would answer for the
                // retry and for the fetch when the track is reached
                prefetch = nil
                refreshInUse()
                retryPrefetch(generation: generation)
                return ok
            }
            guard generation == startGeneration else { return ok }
            // deliberately no recordUse: it hasn't been played yet, and
            // ranking it above the track actually playing would be a lie
            fileCache?.evict()
            return ok
        })
        refreshInUse()
    }

    /// the file the prefetch should be pointed at, or nil when there's nothing
    /// worth pulling ahead of the current track
    private var nextPrefetchFilename: String? {
        // repeat one plays the same file again, which is already on disk
        guard repeatMode != .one else { return nil }
        return queue.next(wrapping: repeatMode == .all)?.song.musicFilename
    }

    /// the prefetch missed & the track that needs it is still minutes out, so
    /// try once more rather than letting the next track arrive cold on a link
    /// that is background-throttled by then. once per track, not a loop: the
    /// fetch at the point of need has a retry of its own
    private func retryPrefetch(generation: Int) {
        guard !prefetchRetried else { return }
        prefetchRetried = true
        prefetchRetry = Task { @MainActor in
            try? await Task.sleep(for: .seconds(prefetchRetryDelay))
            // the track moved on while we waited, or the user stopped it, so
            // whatever is next now isn't wanted yet
            guard !Task.isCancelled, generation == startGeneration, isPlaying else { return }
            prefetchNext()
        }
    }

    private func cancelPrefetch() {
        prefetch?.task.cancel()
        prefetch = nil
        prefetchRetry?.cancel()
        prefetchRetry = nil
    }

    /// the files eviction may not take: the track playing, the one being
    /// fetched behind it, and the cover on screen. the now playing artwork is
    /// read from disk lazily every time the system asks for it, so losing the
    /// file mid-track blanks the cover that is already up
    private func refreshInUse() {
        guard let fileCache else { return }
        var held: Set<String> = []
        if let song {
            held.insert(song.musicFilename)
        }
        if let prefetch {
            held.insert(prefetch.filename)
        }
        fileCache.setInUse(.music, held)
        // only the playing track's cover: nothing pulls artwork ahead, so a
        // prefetched track has no artwork file on disk to protect
        fileCache.setInUse(.artwork, song?.artworkFilename.map { [$0] } ?? [])
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
        // the fetch running for this track starts it itself when it lands, and
        // the item still in the player belongs to the track before it, so all
        // a play here can do is put the intent back for the fetch to find
        if status == .fetching {
            isPlaying = true
            updateNowPlayingPlaybackState()
            return
        }
        // there is nothing loaded to resume — a fetch that didn't land, or an
        // audio session that never activated — so tapping play means start the
        // track again; the state has no other way to recover
        if !hasLoadedTrack {
            startCurrent()
            return
        }
        // play again after the track ended restarts it
        if effectiveEnd > 0 && currentTime >= effectiveEnd {
            seek(to: window.start)
        }
        isPlaying = true
        updateNowPlayingPlaybackState()
        let generation = startGeneration
        Task { @MainActor in
            // the session may have gone inactive after a long pause,
            // interruption or (on the watch) losing its bluetooth output
            guard await activateSession() else {
                if generation == startGeneration {
                    isPlaying = false
                    status = .needsOutput
                    updateNowPlayingPlaybackState()
                }
                return
            }
            guard generation == startGeneration, isPlaying else { return }
            player.play()
        }
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
            // the inserted track is the next one now, so whatever was being
            // pulled ahead is a track further out
            prefetchNext()
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
        updateRemoteCommandModes()
    }

    /// steps the repeat button through off, repeat all & repeat one
    func cycleRepeatMode() {
        setRepeatMode(repeatMode.next)
    }

    func setRepeatMode(_ mode: RepeatMode) {
        repeatMode = mode
        updateRemoteCommandModes()
        // the mode decides what comes next: repeat one has nothing to pull
        // ahead, & repeat all makes the first track next at the end of a queue
        prefetchNext()
    }

    /// reorders the upcoming tracks from the queue view
    func moveUpcoming(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        queue.moveUpcoming(fromOffsets: offsets, toOffset: destination)
        // the reorder may have put a different track next
        prefetchNext()
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
        #if os(watchOS)
        // long form audio is how watchos routes music to bluetooth headphones
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        #else
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
    }

    /// makes the audio session ready for playback; on watchos activation is
    /// async & prompts the user to pick a bluetooth output, which can be
    /// declined, so playback only starts once it succeeds
    private func activateSession() async -> Bool {
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
            // a track that hasn't started yet has no audio to interrupt, and
            // watchos raises one of these as the audio session activates for a
            // bluetooth output; taking the pending start down with it is what
            // left a finished download sitting at a play button
            guard status != .fetching else { break }
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
    private func updateRemoteCommandModes() {
        #if !os(watchOS)
        let center = MPRemoteCommandCenter.shared()
        center.changeShuffleModeCommand.currentShuffleType = queue.isShuffled ? .items : .off
        center.changeRepeatModeCommand.currentRepeatType = repeatMode.repeatType
        #endif
    }

    private func setNowPlayingInfo(for song: Song) {
        var info = Self.baseNowPlayingInfo(for: song, duration: window.duration)
        artworkFetch?.cancel()
        artworkFetch = nil
        if let filename = song.artworkFilename {
            if fileStore.exists(.artwork, filename) {
                info[MPMediaItemPropertyArtwork] = artwork(filename)
            } else if let fetchArtwork {
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
        removeEndObserver()
        // this fires at forwardPlaybackEndTime too, so custom stop times are respected
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleTrackEnd()
            }
        }
    }

    private func removeEndObserver() {
        guard let endObserver else { return }
        NotificationCenter.default.removeObserver(endObserver)
        self.endObserver = nil
    }

    /// a file can be on disk, the right size & still not play — a download
    /// that was truncated without erroring, or a format avfoundation won't
    /// take. nothing surfaces that on its own: the player just sits there
    /// reporting the track as playing, which is indistinguishable from silence
    private func observeStatus(of item: AVPlayerItem) {
        itemStatusObserver?.invalidate()
        let generation = startGeneration
        itemStatusObserver = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            let status = item.status
            guard status != .unknown else { return }
            // the error can't cross into the actor, so reduce it here
            let reason = item.error?.localizedDescription ?? "unknown"
            Task { @MainActor [weak self] in
                guard let self, generation == self.startGeneration else { return }
                if status == .failed {
                    self.handleItemFailure(reason)
                } else {
                    // a track that loaded clears the run of ones that didn't
                    self.consecutiveItemFailures = 0
                }
            }
        }
    }

    /// the file we handed the player is no good. leaving it on disk would be
    /// worse than not having it: every later fetch short circuits on the file
    /// already being there, so the track would never play again. drop it and
    /// treat this like a fetch that missed, which skips on & re-pulls the file
    /// if the queue comes back around to it
    private func handleItemFailure(_ reason: String) {
        guard let song else { return }
        log.error("item failed for \(song.musicFilename, privacy: .public): \(reason, privacy: .public)")
        try? fileStore.delete(.music, song.musicFilename)
        consecutiveItemFailures += 1
        // the file is re-fetchable, so without a budget of its own a queue of
        // tracks that all fail to load would be walked forever, downloading
        // every one of them again on each pass
        guard consecutiveItemFailures < Self.failureLimit else {
            markNotLoaded(.unavailable)
            return
        }
        handleFailedFetch()
    }

    /// a track played through to its finish: count a play, then repeat it,
    /// move on, or stop depending on the repeat mode & queue position
    func handleTrackEnd() {
        if let song {
            onTrackPlayed?(song.id)
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
