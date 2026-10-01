import AVFoundation
import Foundation
import MediaPlayer
import Observation
import OSLog

private let log = Logger(subsystem: "com.jcaffrey.warehouse", category: "player")

@MainActor
@Observable
final class PlayerStore {
    enum MusicPolicy {
        case onDemand
        case downloadedOnly

        static var platformDefault: Self {
            #if os(watchOS)
            .downloadedOnly
            #else
            .onDemand
            #endif
        }
    }

    private(set) var queue = PlayQueue(songs: [])
    /// requested play intent; buffering does not turn it into a pause.
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
    /// what the loaded item is reading: a file on disk, or the server when the
    /// track is streaming. exposed for the tests, which have no other way to
    /// tell the two paths apart
    var currentItemURL: URL? { (player.currentItem?.asset as? AVURLAsset)?.url }
    /// how far ahead the loaded item is asked to buffer, 0 meaning the daemon
    /// decides. exposed for the tests, which have nothing else to read it from
    var forwardBufferDuration: TimeInterval? { player.currentItem?.preferredForwardBufferDuration }
    /// what the item queued behind the current track is reading, nil when the
    /// slot is empty. exposed for the tests, which have no other view of it
    var nextItemURL: URL? { (nextItem?.item.asset as? AVURLAsset)?.url }
    /// the file the prefetch is pulling right now, nil when the slot is free.
    /// exposed for the tests, which otherwise have only the requests that went
    /// out to say what the window is doing
    var prefetchingFilename: String? { prefetch?.filename }
    /// whether the track playing is the item that was already enqueued behind
    /// the last one, rather than one built from scratch. exposed for the
    /// tests: the two read the same url off the same file, so there is nothing
    /// else that tells a step onto the tail apart from a restart
    private(set) var advancedOntoEnqueuedItem = false

    let fileStore: FileStore
    /// the watch bounds what it keeps & passes one in; the phone mirrors the
    /// whole library, so there is nothing to evict and it leaves this nil
    private let fileCache: FileCache?
    /// pulls an artwork file that isn't on disk, for the now playing info. the
    /// downloaded-only playback never calls this; the phone mirrors the
    /// library and leaves it nil
    let fetchArtwork: (@MainActor (String) async -> Bool)?
    /// called with the track id when a track plays through to its finish; the
    /// phone records a play to push back into itunes, the watch leaves it nil
    private let onTrackPlayed: (@MainActor (String) -> Void)?
    private let prefetchDownloader: SingleFileDownloading
    private let downloader: FileDownloader
    /// a queue player so the track after this one can be handed over before it
    /// is needed. an enqueued item is loaded by the media daemon rather than
    /// by us, so it keeps pulling ahead while the app is backgrounded — which
    /// is the whole of a workout, & the only kind of prefetch that works there
    private let player = AVQueuePlayer()
    private static func currentRoute() -> WatchDiagnostic.Detail {
        switch AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType {
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: .bluetooth
        case .headphones: .headphones
        case .builtInSpeaker: .speaker
        default: .otherRoute
        }
    }
    private func waitingReason() -> WatchDiagnostic.WaitingReason? {
        switch player.reasonForWaitingToPlay {
        case .toMinimizeStalls: .minimizeStalls
        case .evaluatingBufferingRate: .evaluatingBufferingRate
        case .noItemToPlay: .noItem
        case nil: nil
        default: .other
        }
    }
    /// kept from the last play call for loading later tracks in the queue
    private var token: String?
    private var baseURL: URL?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    /// watches loading, buffer prediction and transport changes for the current item
    private var cancelPlaybackObservation: (() -> Void)?
    private let observePlayback: PlaybackObservation.Start
    private let diagnostics: WatchDiagnostics
    private var diagnosticID = UUID()
    private var diagnosticStart = Date()
    private var diagnosticWasPlaying = false
    private var diagnosticHasPlayed = false
    private var diagnosticObservedWaiting = false
    private var diagnosticSource: WatchDiagnostic.Source = .http
    private var playbackObservationState: PlaybackObservationState?
    var isActuallyPlaying: Bool {
        isPlaying && playbackObservationState?.timeControlStatus == .playing
            && playbackObservationState?.hasBufferedAudio == true
            && playbackObservationState?.hasPlaybackProgress == true
    }
    /// the same for the enqueued item, which can fail on its own without the
    /// track that is making sound being affected
    private var nextItemStatusObserver: NSKeyValueObservation?
    /// notices the daemon stepping onto the enqueued item, which is the only
    /// sign that a track started when we weren't the ones to start it
    private var currentItemObserver: NSKeyValueObservation?
    var interruptionObserver: NSObjectProtocol?
    var routeChangeObserver: NSObjectProtocol?
    var remoteCommandsConfigured = false
    /// on watchos the session activates asynchronously (it can prompt for a
    /// bluetooth output) & needs re-activating after the route goes away
    var sessionActivated = false
    /// set when the user scrubs past the stop time, so the track plays
    /// through to the end of the file instead of stopping right away
    private var ignoresFinish = false
    /// seeks the player hasn't finished yet; the time observer stays quiet
    /// until they land so the playhead doesn't flick back to the old position
    private var pendingSeeks = 0
    /// where the track being loaded right now will start, nil once it has
    /// started. the track before it may still be playing on underneath while
    /// its file downloads, dragging the clock with it, so the position can't
    /// just be read back off currentTime when the item finally lands
    private(set) var pendingStartTime: TimeInterval?
    /// a playhead a restored queue hasn't started at yet. consumed by the
    /// start that picks the track up, so a position saved before the app died
    /// can't follow the queue on to some later track
    private var resumeTime: TimeInterval?
    /// bumped every time a new track starts, so a download that finishes after
    /// the user has moved on doesn't hijack playback
    private(set) var startGeneration = 0
    /// the one fetch running ahead of the current track, kept by name so
    /// starting that very track can join it instead of racing a second
    /// download of the same file. the window decides what goes in here next;
    /// the slot itself stays single, since transfers running alongside each
    /// other over one slow link finish later than the same transfers in a row
    private var prefetch: (filename: String, task: Task<Bool, Never>)?
    /// how much of what the prefetch is working through eviction may not
    /// touch. this is the protection set rather than the reach, & it has to
    /// stay small: every name in it is a track eviction can't reclaim, and on
    /// the 256 mb floor budget ten tracks is already about a fifth of the
    /// cache. how far the chain actually pulls is `deepPrefetchDepth`
    private static let protectionDepth = 10
    /// the one item enqueued behind the current track. the play queue stays
    /// the source of truth for order, history, shuffle & repeat; this is a
    /// derived cache of the single slot after it
    private var nextItem: NextItem?
    /// a queue row whose enqueued item wouldn't load, so re-pointing the slot
    /// can't put the same broken item straight back into the player
    private var failedNextEntryID: UUID?
    /// the second attempt at a prefetch that missed, waiting out the rest of
    /// its delay
    private var prefetchRetry: Task<Void, Never>?
    /// whether this track has already spent its one prefetch retry, so a miss
    /// on a dead link can't turn into a loop
    private var prefetchRetried = false
    /// the now playing artwork being fetched for the current track, cancelled
    /// when another track starts
    var artworkFetch: Task<Void, Never>?
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
    let activateSessionForTests: (@MainActor () async -> Bool)?
    /// whether a track that isn't on disk is handed to the player as a server
    /// url rather than downloaded first. downloaded-only playback prevents
    /// both paths regardless of this setting
    private let streams: Bool
    private let musicPolicy: MusicPolicy
    private(set) var downloadedOnly: Bool
    var onPrefetchDemand: (@MainActor ([String]) -> Void)?
    /// how far ahead of the playhead a stream is asked to buffer. the default
    /// is 0, meaning the media daemon picks, and it picks for the general case
    /// rather than for a watch that is about to lose signal under a bridge; a
    /// minute of slack is the difference between riding a dead zone out and
    /// stopping. long enough to cover one, short enough not to pull most of a
    /// track down before the user has skipped it. only ever a hint — the
    /// daemon may buffer less, so nothing here assumes the audio is there
    private static let streamForwardBufferDuration: TimeInterval = 60
    /// whether the item in the player is reading from the server. a stream has
    /// no file of ours behind it, so the things that clean up after a bad
    /// download have nothing to clean up
    private(set) var isStreamingCurrentTrack = false
    /// how far past the track about to play the prefetch keeps pulling while
    /// the app is frontmost, which is the only transfer time the watch gets
    /// that isn't background-budgeted or throttled. 0 is off: the first slot
    /// is the whole of it — a gap-free boundary, & all a streaming track can
    /// afford. deeper is for putting a playlist on & walking out of signal
    /// with the whole of it on disk, which is a lot of link time to spend and
    /// is nobody's default; the watch takes it from a setting on the phone,
    /// and the phone leaves it off — it mirrors the library already
    var deepPrefetchDepth = 0
    /// whether the app is frontmost. prefetch is a cache fill, not the path
    /// that makes sound, and it shares one slow link with whatever is
    /// streaming right now — so it only runs where the user can see it. during
    /// a workout the app is never active, which is exactly when pulling the
    /// next track ahead would starve the stream it is meant to cover for
    private var isForeground = true

    /// the item queued behind the one playing, and what it stands for
    private struct NextItem {
        /// the queue row it was built for, so a reorder can tell whether it is
        /// still the track that plays next
        let entryID: UUID
        let songID: String
        let filename: String
        let item: AVPlayerItem
        /// reading from the server rather than off disk
        let streaming: Bool
    }

    // the retry delay & activation parameters are here for tests
    init(
        fileStore: FileStore,
        client: LibraryClient = LibraryClient(),
        fileCache: FileCache? = nil,
        prefetchDownloader: SingleFileDownloading? = nil,
        fetchArtwork: (@MainActor (String) async -> Bool)? = nil,
        onTrackPlayed: (@MainActor (String) -> Void)? = nil,
        streams: Bool = false,
        musicPolicy: MusicPolicy = .platformDefault,
        retryDelay: TimeInterval = 1,
        prefetchRetryDelay: TimeInterval = 30,
        activateSessionForTests: (@MainActor () async -> Bool)? = nil,
        observePlayback: @escaping PlaybackObservation.Start = PlaybackObservation.start,
        diagnostics: WatchDiagnostics? = nil
    ) {
        self.fileStore = fileStore
        self.fileCache = fileCache
        self.fetchArtwork = fetchArtwork
        self.onTrackPlayed = onTrackPlayed
        self.streams = streams
        self.musicPolicy = musicPolicy
        self.downloadedOnly = musicPolicy == .downloadedOnly
        self.retryDelay = retryDelay
        self.prefetchRetryDelay = prefetchRetryDelay
        self.activateSessionForTests = activateSessionForTests
        self.observePlayback = observePlayback
        self.diagnostics = diagnostics ?? .shared
        self.downloader = FileDownloader(client: client, fileStore: fileStore)
        self.prefetchDownloader = prefetchDownloader ?? self.downloader
        // the point of the queue: at the end of a track the daemon plays
        // straight on into the item behind it instead of waiting for us
        player.actionAtItemEnd = .advance
        // the category only declares intent, nothing is activated & no other
        // app's audio stops, but it has to be set before the route picker can
        // report the real output for a restored queue that hasn't played yet
        configureAudioSessionIfNeeded()
        observeAudioSession()
        observeCurrentItem()
    }

    /// the state worth keeping when the app goes away, nil when there is
    /// nothing playing to come back to
    var snapshot: PlaybackSnapshot? {
        guard queue.current != nil else { return nil }
        return PlaybackSnapshot(
            queue: queue.snapshot, repeatMode: repeatMode, currentTime: currentTime)
    }

    /// puts a stored queue back the way it was left: the track is current & the
    /// playhead is where it stopped, but nothing is loaded & nothing is fetched
    /// until the user asks for it, so opening the app makes no sound of its own.
    /// ignored once anything is playing — a queue the user just started is the
    /// one they want, not the one from last time
    func restore(_ snapshot: PlaybackSnapshot, songs: [String: Song], token: String?, baseURL: URL?) {
        guard queue.current == nil,
              var restored = PlayQueue(snapshot: snapshot.queue, songs: songs) else { return }
        let previousID = restored.current?.id
        if downloadedOnly {
            restored.retainSongs { fileStore.exists(.music, $0.musicFilename) }
        }
        guard let song = restored.current?.song else { return }
        queue = restored
        repeatMode = snapshot.repeatMode
        self.token = token
        self.baseURL = baseURL
        window = PlaybackWindow(duration: song.duration, start: song.start, finish: song.finish)
        currentTime = restored.current?.id == previousID
            ? min(max(snapshot.currentTime, window.start), window.duration) : window.start
        resumeTime = currentTime
        status = .ready
        isPlaying = false
        // the lock screen & the remote commands are left alone: they belong to
        // whatever is making sound, & this is a queue nobody has played yet
    }

    /// keeps the credentials a restored queue will fetch with current; a token
    /// stored with the queue would be the one that expired while the app was gone
    func setCredentials(token: String?, baseURL: URL?) {
        guard queue.current != nil else { return }
        guard self.token != token || self.baseURL != baseURL else { return }
        self.token = token
        self.baseURL = baseURL
        cancelPrefetch()
        if nextItem?.streaming == true {
            removeNextItem()
            reconcileNextItem()
        }
        prefetchNext()
    }

    /// starts playing songs in order, positioned at the tapped one so previous
    /// walks back through the earlier tracks; replaces the current queue and
    /// turns repeat off
    func play(_ songs: [Song], startingAt index: Int = 0, token: String?, baseURL: URL?, downloadedOnly: Bool = false) {
        playSongs(songs, startingAt: index, token: token, baseURL: baseURL, downloadedOnly: downloadedOnly, preservingModes: false)
    }

    /// starts at a selected track while keeping the current shuffle and repeat modes
    func playSelected(_ songs: [Song], startingAt index: Int, token: String?, baseURL: URL?, downloadedOnly: Bool = false) {
        playSongs(songs, startingAt: index, token: token, baseURL: baseURL, downloadedOnly: downloadedOnly, preservingModes: true)
    }

    private func playSongs(
        _ songs: [Song], startingAt index: Int, token: String?, baseURL: URL?,
        downloadedOnly: Bool, preservingModes: Bool
    ) {
        let downloadedOnly = musicPolicy == .downloadedOnly || downloadedOnly
        let playable = downloadedOnly ? songs.filter { fileStore.exists(.music, $0.musicFilename) } : songs
        guard !playable.isEmpty else { return }
        let target = songs.dropFirst(max(0, index)).first { !downloadedOnly || fileStore.exists(.music, $0.musicFilename) }
        let startIndex = downloadedOnly ? (target.flatMap { playable.firstIndex(of: $0) } ?? 0) : index
        self.downloadedOnly = downloadedOnly
        if downloadedOnly { cancelPrefetch() }
        var newQueue = PlayQueue(songs: playable, startingAt: startIndex)
        if preservingModes && queue.isShuffled {
            newQueue.setShuffled(true)
        }
        start(newQueue, repeating: preservingModes ? repeatMode : .off, token: token, baseURL: baseURL)
    }

    /// starts playing songs in a random order; replaces the current queue and
    /// repeats it once it runs out
    func playShuffled(_ songs: [Song], token: String?, baseURL: URL?, downloadedOnly: Bool = false) {
        let downloadedOnly = musicPolicy == .downloadedOnly || downloadedOnly
        let playable = downloadedOnly ? songs.filter { fileStore.exists(.music, $0.musicFilename) } : songs
        guard !playable.isEmpty else { return }
        self.downloadedOnly = downloadedOnly
        if downloadedOnly { cancelPrefetch() }
        start(PlayQueue(shuffling: playable), repeating: .all, token: token, baseURL: baseURL)
    }

    private func start(_ newQueue: PlayQueue, repeating mode: RepeatMode, token: String?, baseURL: URL?) {
        guard newQueue.current != nil else { return }
        // a queue the user just picked starts with a clean slate; whatever the
        // last one couldn't fetch or load shouldn't count against it
        consecutiveFailures = 0
        consecutiveItemFailures = 0
        // & neither should it start at the playhead a restored queue was left at
        resumeTime = nil
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
        if downloadedOnly, let song, !fileStore.exists(.music, song.musicFilename) {
            queue.retainSongs { fileStore.exists(.music, $0.musicFilename) }
            resumeTime = nil
            guard queue.current != nil else {
                markNotLoaded(.unavailable)
                return
            }
        }
        guard let song else { return }
        diagnosticID = UUID()
        diagnosticStart = Date()
        diagnosticWasPlaying = false
        diagnosticHasPlayed = false
        diagnosticObservedWaiting = false
        startGeneration += 1
        let generation = startGeneration
        cancelPlaybackObservation?()
        cancelPlaybackObservation = nil
        playbackObservationState = nil
        // the retry budget is per track start, not per session
        prefetchRetried = false
        // whatever was lined up behind the track we're leaving stands for a
        // different position in the queue now
        removeNextItem()
        failedNextEntryID = nil

        let isDownloaded = fileStore.exists(.music, song.musicFilename)
        diagnosticSource = isDownloaded ? .cache : .http
        diagnostics.record(.init(kind: .playbackRequested, id: diagnosticID,
                                 source: diagnosticSource,
                                 detail: Self.currentRoute()))
        // a prefetch already running for this very track is the fetch we're
        // about to need, so let it finish; so is one for a track still ahead
        // of us in the chain, which is progress on the same slow link.
        // anything else has been superseded
        if let running = prefetch?.filename,
           running != song.musicFilename, !prefetchReach.contains(running) {
            cancelPrefetch()
        }
        // hold the file against eviction before anything else touches disk,
        // and release the track we just moved off
        refreshInUse()
        // without the file or a way to fetch it there's nothing to play
        guard isDownloaded || (!downloadedOnly && token != nil && baseURL != nil) else {
            markNotLoaded(.unavailable)
            return
        }

        configureAudioSessionIfNeeded()
        configureRemoteCommandsIfNeeded()

        window = PlaybackWindow(duration: song.duration, start: song.start, finish: song.finish)
        // a restored track resumes at the playhead it was saved at, unless it
        // sits outside the window, in which case it starts over
        let resume = resumeTime.flatMap { $0 > window.start && $0 < window.end ? $0 : nil }
        resumeTime = nil
        pendingStartTime = resume ?? window.start
        currentTime = resume ?? window.start
        ignoresFinish = false
        isPlaying = true
        // play intent goes up before sound starts; distinguish the two kinds of waiting.
        status = isDownloaded ? .ready : (streams ? .buffering : .fetching)
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
                // hand the server url straight to the player where we can: the
                // loading then happens outside this process & survives the app
                // being backgrounded, which a download at a track boundary
                // does not
                if streams, let asset = StreamingAsset.make(
                    .music, filename: song.musicFilename, token: token, baseURL: baseURL) {
                    beginPlayback(of: song, streaming: asset)
                    return
                }
                status = .fetching
                let ok = await fetchMusic(
                    song.musicFilename, token: token, baseURL: baseURL, generation: generation)
                guard generation == startGeneration else { return }
                if ok {
                    fileCache?.recordUse(.music, song.musicFilename)
                    // the track is on disk now, so the rows showing what's
                    // cached are out of date until they're told
                    fileCache?.noteMusicStored()
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
        startGeneration += 1
        pendingStartTime = nil
        player.pause()
        removeEndObserver()
        cancelPlaybackObservation?()
        cancelPlaybackObservation = nil
        playbackObservationState = nil
        cancelPrefetch()
        removeNextItem()
        player.removeAllItems()
        // the item it described is gone, & left set it would have prefetch
        // standing down for a stream that isn't there any more
        isStreamingCurrentTrack = false
        isPlaying = false
        status = reason
        updateNowPlayingPlaybackState()
    }

    /// swaps the downloaded file into the player and starts it, unless the user
    /// paused while it was still downloading
    private func beginPlayback(of song: Song) {
        beginPlayback(of: song, item: AVPlayerItem(url: fileStore.fileURL(.music, song.musicFilename)))
    }

    /// plays the track off the server rather than off disk. the item goes into
    /// the player right away & buffers there, so unlike a download this leaves
    /// no silent stretch for watchos to suspend the app in
    private func beginPlayback(of song: Song, streaming asset: AVURLAsset) {
        beginPlayback(of: song, item: AVPlayerItem(asset: asset), streaming: true)
    }

    private func beginPlayback(of song: Song, item: AVPlayerItem, streaming: Bool = false) {
        // something is playing again, so whatever was skipped to get here
        // doesn't count toward giving up on the queue
        consecutiveFailures = 0
        isStreamingCurrentTrack = streaming
        advancedOntoEnqueuedItem = false
        observeEnd(of: item)
        observeTimeIfNeeded()

        // the player's queue is rebuilt around this item; the slot behind it
        // is filled again below, once the track we're actually on is known
        player.removeAllItems()
        player.insert(item, after: nil)
        applyStopTime()
        let start = pendingStartTime ?? window.start
        pendingStartTime = nil
        // the last track's item may have been playing on underneath this one
        // while it was fetched, dragging the clock along with it
        currentTime = start
        if start > 0 {
            seekPlayer(to: start)
        }
        if isPlaying {
            player.play()
        }
        status = streaming ? .buffering : .ready
        observeStatus(of: item)
        updateNowPlayingPlaybackState()
        // the gap between tracks is only hidden if the next one is already
        // here, so start it now rather than when the current track ends
        prefetchNext()
        reconcileNextItem()
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

    /// works through the queue ahead of the playhead, one transfer at a time,
    /// while the current track plays. failures are silent: the track falls
    /// back to being fetched when it's actually reached & nothing about the
    /// playing track changes.
    ///
    /// safe to call at any point — the queue is re-read every time — so the
    /// watch re-arms it when it comes back to the foreground, where transfers
    /// aren't throttled, rather than living with the one shot it gets as a
    /// track starts
    func prefetchNext() {
        if let onPrefetchDemand {
            let allowed = !downloadedOnly && isPlaying && isForeground && (!isStreamingCurrentTrack || streamAllowsPrefetch)
            onPrefetchDemand(allowed ? (isStreamingCurrentTrack ? Array(prefetchReach.prefix(1)) : prefetchReach) : [])
            return
        }
        guard !downloadedOnly else { return }
        // current audio gets the link while buffering; paused intent must not
        // start cache work when a delayed observation or retry arrives.
        guard isPlaying else { return }
        if isStreamingCurrentTrack, !streamAllowsPrefetch {
            cancelPrefetch()
            return
        }
        let reach = prefetchReach
        if let running = prefetch?.filename {
            if !reach.contains(running) {
                // superseded: there is nothing left that wants this file
                cancelPrefetch()
            } else if let first = reach.first, running != first,
                      !fileStore.exists(.music, first) {
                // it is still in the window, but the track about to play is
                // cold and something further out is holding the link. a
                // gap-free boundary is what prefetch is for, so the deeper
                // transfer gives way — its bytes are worth less than a silence
                cancelPrefetch()
            }
            // anything else moved further out & is still wanted, and throwing
            // away a transfer in flight is what the whole thing avoids
        }
        guard let token, let baseURL else { return }
        // backgrounded, this is a download competing with a stream over one
        // slow link, for a track that can stream itself when it's reached.
        // one already running is left to finish — it is a single track & has
        // progress worth keeping — but no new one starts out of sight
        guard isForeground else { return }
        // one at a time: restarting a transfer in flight would throw away its
        // progress on exactly the slow link that makes prefetching worth doing
        guard prefetch == nil else { return }
        // a streaming track is already spending the link to make sound, so
        // there is no spare capacity to fill a cache with: the reach shrinks
        // to the one track that has to be there for a gap-free boundary. one
        // that is already in flight is left alone — the cancel above uses the
        // full reach — since its progress outlives whatever is streaming now
        let reachable = isStreamingCurrentTrack ? Array(reach.prefix(1)) : reach
        // tracks already on disk aren't work, but they don't shorten the
        // reach either — a queue of mostly-cached tracks still reaches past
        // them to the ones that are missing
        guard let filename = reachable.first(where: { !fileStore.exists(.music, $0) }) else { return }
        if filename != reach.first {
            // past the first slot this is cache filling rather than the track
            // about to play, so it only runs while there is disk left to fill:
            // once the music on disk is at its budget the chain stops for
            // good, rather than evicting a track it pulled a minute ago to
            // make room for the next one. what re-arms it is a track start, a
            // queue mutation or a foreground return — the same shape a deep
            // failure has — which bounds the churn to one refetch at a track
            // boundary instead of a tight loop against eviction. the phone has
            // no cache & no reach: it mirrors the library, and a second copy
            // of its own sync is all this would be there
            guard let fileCache, fileCache.musicRoom() > 0 else { return }
        }
        // the retry budget belongs to the track that is about to play, so a
        // miss deeper in the queue must not spend it
        let isNextTrack = filename == reach.first

        let generation = startGeneration
        prefetch = (filename, Task { @MainActor in
            let ok = await prefetchDownloader.download(.music, filename: filename, token: token, baseURL: baseURL)
            guard !Task.isCancelled else { return ok }
            guard ok else {
                // a finished task hands the same answer to everything that
                // joins it, so a failure left in place would answer for the
                // retry and for the fetch when the track is reached
                prefetch = nil
                refreshInUse()
                // the chain stops here; the next track start & the next
                // foreground return both re-arm it from the top
                if isNextTrack {
                    retryPrefetch(generation: generation)
                }
                return ok
            }
            // the slot is free for the next track along. what holds this file
            // against eviction from here on is the protection window, which
            // refreshInUse reads — so it has to run before evict does
            prefetch = nil
            refreshInUse()
            // deliberately no recordUse: it hasn't been played yet, and
            // ranking it above the track actually playing would be a lie
            fileCache?.noteMusicStored()
            if isNextTrack {
                // the track about to play is fetched whatever the budget says,
                // so this is where the cache turns over: eviction makes the
                // room it just took. a deep fetch deliberately doesn't evict —
                // it stopped at the budget, and evicting here would hand the
                // room straight back to the chain that is meant to have
                // stopped, which is the ping-pong the cap exists to prevent
                fileCache?.evict()
            }
            guard generation == startGeneration else { return ok }
            // the file is here now, so the slot behind the current track can
            // hold it rather than holding nothing at all
            reconcileNextItem()
            // on to the rest of the queue; the guards above decide whether
            // there is still room and a link to spare
            prefetchNext()
            return ok
        })
        refreshInUse()
    }

    /// tracks whether the app is frontmost, which is the only place prefetch
    /// runs. coming back to the foreground is also the chance to fill a miss,
    /// so it re-arms on the way in
    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        if isPlaying {
            prefetchNext()
        }
    }

    /// the tracks the prefetch works through, nearest first: the one that
    /// plays next, then as far into the queue behind it as the deep depth
    /// allows. empty when there is nothing worth pulling ahead of the current
    /// track, one long when the deep fetch is off.
    ///
    /// the first slot is exactly what it has always been, wrapping at the end
    /// of a repeating queue. the rest is the plain upcoming order, which does
    /// not wrap — past the wrap are tracks the user has just heard, and they
    /// are on disk far more often than not. the depth is a setting rather than
    /// a constant, which is also what keeps the walk below finite: this runs
    /// on every track start, every queue mutation and every completed transfer
    private var prefetchReach: [String] {
        prefetchNames(depth: deepPrefetchDepth)
    }

    /// the front of the reach: what eviction may not touch while the chain
    /// works through it. deep enough that the front can't be taken while the
    /// back is still coming down, & bounded so that a reach of a few thousand
    /// tracks doesn't pin the cache shut behind it. taken at its own depth
    /// rather than off the front of the reach, since refreshInUse asks for it
    /// on every change to the fetch in flight & the reach can be long
    private var prefetchWindow: [String] {
        prefetchNames(depth: min(deepPrefetchDepth, Self.protectionDepth - 1))
    }

    private func prefetchNames(depth: Int) -> [String] {
        // repeat one plays the same file again, which is already on disk
        guard repeatMode != .one,
              let next = queue.next(wrapping: repeatMode == .all) else { return [] }
        // upcoming's head is that same entry whenever the queue hasn't wrapped
        return [next.song.musicFilename] + queue.upcoming
            .dropFirst()
            .prefix(depth)
            .map(\.song.musicFilename)
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
        onPrefetchDemand?([])
        prefetch?.task.cancel()
        prefetch = nil
        prefetchRetry?.cancel()
        prefetchRetry = nil
    }

    private var streamAllowsPrefetch: Bool {
        guard isPlaying, let state = playbackObservationState else { return false }
        return state.itemStatus == .readyToPlay && state.likelyToKeepUp
            && state.timeControlStatus == .playing && state.hasBufferedAudio && state.hasPlaybackProgress
    }

    func downloadsChanged() {
        if downloadedOnly {
            // leave the current track alone while its loaded audio may still play.
            let currentID = song?.id
            queue.retainSongs { $0.id == currentID || fileStore.exists(.music, $0.musicFilename) }
        }
        reconcileNextItem()
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
        if let nextItem {
            // an enqueued item can be reading a file off disk, & a cache that
            // deletes a track already queued to play leaves a gap with no way
            // back: nothing re-points the slot before the daemon reaches it
            held.insert(nextItem.filename)
        }
        // the front of what the prefetch is working through, so eviction
        // can't take the head of it while the back is still coming down. names
        // with no file behind them cost nothing — eviction only ever looks at
        // what is on disk — and the window bounds this to a handful of tracks.
        // what the chain pulls past the window is deliberately left evictable:
        // a fresh fetch has never been played, so it falls back to createdAt &
        // sorts newest, which puts genuinely old tracks ahead of it anyway
        held.formUnion(prefetchWindow)
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
        playbackObservationState?.timeControlStatus = .paused
        cancelPrefetch()
        updateNowPlayingPlaybackState()
    }

    func resume() {
        guard song != nil, !isPlaying else { return }
        // activation or a file fetch still owns the pending start. a stream
        // already handed to the player instead needs a real transport resume.
        if pendingStartTime != nil {
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
            status = isStreamingCurrentTrack ? .buffering : .ready
            player.play()
            prefetchNext()
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
        // the next track is already enqueued & loading, so step onto it rather
        // than tearing it down and starting it over from nothing
        if advanceOntoNextItem(.skipped) { return }
        if queue.advance(wrapping: repeatMode == .all) {
            startCurrent()
        } else {
            stop()
        }
    }

    /// queues a song right after the current track, or just plays it when
    /// nothing is queued
    func playNext(_ song: Song, token: String?, baseURL: URL?) {
        guard !downloadedOnly || fileStore.exists(.music, song.musicFilename) else { return }
        if queue.current == nil {
            play([song], token: token, baseURL: baseURL, downloadedOnly: downloadedOnly)
        } else {
            queue.playNext(song)
            // the inserted track is the next one now, so whatever was being
            // pulled ahead is a track further out
            prefetchNext()
            reconcileNextItem()
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
        guard !downloadedOnly || fileStore.exists(.music, song.musicFilename) else { return }
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
        // an edit to the track queued behind this one moves the marker the
        // daemon advances at, which was armed when the item was enqueued
        if let nextItem, nextItem.songID == song.id {
            nextItem.item.forwardPlaybackEndTime = Self.stopTime(for: song)
        }
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
        // a reshuffle rewrites the whole window, not just what comes next, so
        // the prefetch is pointed at tracks that may be nowhere near now
        prefetchNext()
        // & unlike a prefetch that went to the wrong file, an item left in the
        // player would be played
        reconcileNextItem()
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
        reconcileNextItem()
    }

    /// reorders the upcoming tracks from the queue view
    func moveUpcoming(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        queue.moveUpcoming(fromOffsets: offsets, toOffset: destination)
        // the reorder may have put a different track next
        prefetchNext()
        reconcileNextItem()
    }

    func seek(to time: TimeInterval) {
        guard song != nil else { return }
        currentTime = min(max(0, time), window.duration)
        ignoresFinish = window.stopsEarly && currentTime >= window.end
        // scrubbing a track that hasn't started yet — a restored queue, or one
        // still being fetched — moves where it will start instead
        if resumeTime != nil {
            resumeTime = currentTime
        }
        if pendingStartTime != nil {
            pendingStartTime = currentTime
        }
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
        let generation = startGeneration
        // this fires at forwardPlaybackEndTime too, so custom stop times are respected
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // a notification already on its way to the main queue when the
                // daemon's own advance was picked up would otherwise count the
                // finished track a second time & skip the one after it
                guard let self, generation == self.startGeneration else { return }
                self.handleTrackEnd()
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
        cancelPlaybackObservation?()
        playbackObservationState = nil
        diagnosticSource = (item.asset as? AVURLAsset)?.url.isFileURL == true ? .cache : .http
        let generation = startGeneration
        let identity = ObjectIdentifier(item)
        cancelPlaybackObservation = observePlayback(player, item) { [weak self] state in
            guard let self, generation == self.startGeneration else { return }
            // the daemon may already have advanced off a failed current item.
            // failure handling still owns that transition for this generation.
            if state.itemStatus == .failed {
                self.handleItemFailure(state.failureReason)
                return
            }
            guard let current = self.player.currentItem, ObjectIdentifier(current) == identity else { return }
            let couldPrefetch = self.streamAllowsPrefetch
            self.playbackObservationState = state
            let actuallyPlaying = self.isActuallyPlaying
            if !self.isPlaying {
                self.diagnosticWasPlaying = false
            } else if actuallyPlaying != self.diagnosticWasPlaying {
                let kind: WatchDiagnostic.Kind = actuallyPlaying
                    ? (self.diagnosticHasPlayed ? .playbackRecovered : .playbackStarted)
                    : .playbackStalled
                if actuallyPlaying { self.diagnosticHasPlayed = true }
                self.diagnosticWasPlaying = actuallyPlaying
                self.recordPlayback(kind, item: current)
            } else if !actuallyPlaying && !self.diagnosticHasPlayed && !self.diagnosticObservedWaiting {
                self.diagnosticObservedWaiting = true
                self.recordPlayback(.playbackBuffering, item: current)
            }
            if state.itemStatus == .readyToPlay {
                self.consecutiveItemFailures = 0
                if self.isStreamingCurrentTrack, current.preferredForwardBufferDuration != Self.streamForwardBufferDuration {
                    current.preferredForwardBufferDuration = Self.streamForwardBufferDuration
                }
            }
            if self.isStreamingCurrentTrack, self.status != .needsOutput {
                self.status = state.itemStatus == .readyToPlay && self.isActuallyPlaying
                    ? .ready : .buffering
            }
            self.updateNowPlayingPlaybackState()
            if self.isStreamingCurrentTrack, self.streamAllowsPrefetch != couldPrefetch {
                self.prefetchNext()
            }
        }
    }

    private func recordPlayback(_ kind: WatchDiagnostic.Kind, item: AVPlayerItem) {
        let ranges = item.loadedTimeRanges.map(\.timeRangeValue)
        let position = item.currentTime().seconds
        let buffer = ranges.filter { $0.start.seconds <= position && position < $0.end.seconds }
            .map { $0.end.seconds - position }.filter(\.isFinite).max()
        let access = item.accessLog()?.events.last
        diagnostics.record(.init(kind: kind, id: diagnosticID, source: diagnosticSource,
                                 bytes: access.map { Int64($0.numberOfBytesTransferred) },
                                 throughput: access?.observedBitrate, bufferSeconds: buffer,
                                 elapsed: Date().timeIntervalSince(diagnosticStart), detail: Self.currentRoute(),
                                 waitingReason: kind == .playbackStarted || kind == .playbackRecovered ? nil : waitingReason()))
    }

    /// the file we handed the player is no good. leaving it on disk would be
    /// worse than not having it: every later fetch short circuits on the file
    /// already being there, so the track would never play again. drop it and
    /// treat this like a fetch that missed, which skips on & re-pulls the file
    /// if the queue comes back around to it
    private func handleItemFailure(_ reason: String) {
        guard let song else { return }
        diagnostics.record(.init(kind: .playbackFailed, id: diagnosticID, source: diagnosticSource,
                                 elapsed: Date().timeIntervalSince(diagnosticStart), detail: Self.currentRoute()))
        log.error("item failed for \(song.musicFilename, privacy: .public): \(reason, privacy: .public)")
        // only a file we wrote can be the bad one. a stream that failed says
        // something about the link, not about the disk — and by the time it
        // fails a prefetch may well have landed the very file it was standing
        // in for, which deleting would throw away
        if !isStreamingCurrentTrack {
            try? fileStore.delete(.music, song.musicFilename)
            fileCache?.noteMusicStored()
        }
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

    /// why the player moved onto the item enqueued behind the current track
    private enum Advance {
        /// the track played through to its end, so it counts as a play & the
        /// audio session is by definition still live
        case trackEnded
        /// the user stepped onto it, which is no play at all & can happen long
        /// after the session went away
        case skipped
        /// the daemon moved onto it without us asking. this exists so the play
        /// queue can follow the player, & deliberately reports no play whatever
        /// the reason for the move: didPlayToEndTime is the only signal that a
        /// track actually reached its end, so handleTrackEnd is the only path
        /// that writes a play back into itunes. a fabricated play is then not
        /// something a guard has to prevent — there is no call here to make one
        case daemonAdvanced
    }

    /// the player is on the item that was enqueued behind the current track.
    /// this is where the play queue follows the player instead of driving it:
    /// the daemon advances on its own with the app backgrounded, and nothing
    /// else here would ever find out that a new track had started.
    ///
    /// false when the slot isn't holding what the queue says plays next,
    /// leaving the caller to start the right track from scratch
    @discardableResult
    private func advanceOntoNextItem(_ reason: Advance) -> Bool {
        guard let next = nextItem, let target = nextEnqueueEntry, target.id == next.entryID,
              let finished = song else { return false }
        if downloadedOnly, !fileStore.exists(.music, next.filename) {
            removeNextItem()
            return false
        }
        // emptied before the player moves, so the currentItem observation this
        // is about to set off finds nothing left to do: the end notification &
        // the observation both land here for the same advance
        nextItem = nil
        nextItemStatusObserver?.invalidate()
        nextItemStatusObserver = nil
        if player.currentItem !== next.item {
            // didPlayToEndTime can arrive before the daemon has stepped off the
            // finished item, & at a custom stop time it is the only thing that
            // knows the track is over at all
            player.advanceToNextItem()
        }
        guard player.currentItem === next.item else {
            // the slot isn't what's playing, so there is nothing here to follow
            player.remove(next.item)
            return false
        }

        // a track the daemon started is a track start like any other, so
        // everything captured for the one before it — a fetch still in flight,
        // a prefetch retry, an artwork pull, the old item's end & status
        // observers — has to go stale right here. without it the finish of a
        // track nobody heard reports a play against the wrong id
        startGeneration += 1
        prefetchRetried = false
        failedNextEntryID = nil
        // something is playing again, so whatever was skipped to get here
        // doesn't count toward giving up on the queue
        consecutiveFailures = 0
        if reason == .trackEnded {
            onTrackPlayed?(finished.id)
        }
        queue.advance(wrapping: repeatMode == .all)
        guard let song else { return true }

        if !next.streaming {
            fileCache?.recordUse(.music, song.musicFilename)
        }
        isStreamingCurrentTrack = next.streaming
        diagnosticID = UUID()
        diagnosticStart = Date()
        diagnosticWasPlaying = false
        diagnosticHasPlayed = false
        diagnosticObservedWaiting = false
        diagnosticSource = next.streaming ? .http : .cache
        diagnostics.record(.init(kind: .playbackRequested, id: diagnosticID,
                                 source: diagnosticSource, detail: Self.currentRoute()))
        advancedOntoEnqueuedItem = true
        observeEnd(of: next.item)
        window = PlaybackWindow(duration: song.duration, start: song.start, finish: song.finish)
        currentTime = window.start
        ignoresFinish = false
        isPlaying = true
        // an item that has been enqueued for a while may already be holding, in
        // which case the status observer clears this on its first callback
        status = next.streaming ? .buffering : .ready
        observeStatus(of: next.item)
        setNowPlayingInfo(for: song)
        applyStopTime()
        if window.start > 0 {
            seekPlayer(to: window.start)
        }
        updateNowPlayingPlaybackState()
        refreshInUse()
        prefetchNext()
        reconcileNextItem()
        if reason == .skipped {
            reactivateSessionForSkip()
        }
        return true
    }

    /// stepping onto an enqueued item skips the activation a track start does,
    /// & on the watch the session may have gone since — losing a bluetooth
    /// output is exactly the thing a user skips a track around. an advance at
    /// the end of a track needs none of this: audio was rendering a moment ago
    private func reactivateSessionForSkip() {
        let generation = startGeneration
        Task { @MainActor in
            guard await activateSession() else {
                if generation == startGeneration {
                    markNotLoaded(.needsOutput)
                }
                return
            }
            guard generation == startGeneration, isPlaying else { return }
            player.play()
        }
    }

    /// the media daemon steps onto the enqueued item by itself at the end of a
    /// track, without this app being scheduled at all. this is the only place
    /// that finds out, so it is what keeps the play queue in step
    private func observeCurrentItem() {
        currentItemObserver = player.observe(\.currentItem, options: [.old, .new]) { [weak self] _, change in
            // neither item can cross into the actor, so both are reduced here:
            // the identity of what is playing now, and whether what the player
            // stepped off failed rather than finished
            guard let item = change.newValue ?? nil else { return }
            let identity = ObjectIdentifier(item)
            let previousFailed = (change.oldValue ?? nil)?.status == .failed
            Task { @MainActor [weak self] in
                guard let self, let next = self.nextItem,
                      identity == ObjectIdentifier(next.item) else { return }
                // the player steps off an item that failed as readily as one
                // that ended. handleItemFailure owns that case — it drops a bad
                // file, counts the failure against the give-up budget & skips —
                // & following the move here would bump the generation out from
                // under it, so none of that would run
                guard !previousFailed else { return }
                // nothing here moves the player onto the enqueued item without
                // emptying the slot first, so this is the daemon's own advance
                self.advanceOntoNextItem(.daemonAdvanced)
            }
        }
    }

    /// keeps one item enqueued behind the one playing, pointed at whatever the
    /// play queue says comes next. this is the only kind of pulling ahead that
    /// works mid-workout: the loading is the daemon's, not ours
    private func reconcileNextItem() {
        let target = nextEnqueueEntry
        // a stream in the slot is only what there was to point it at when it
        // was filled. the prefetch running behind it lands the file part way
        // through the track in front, & leaving the item alone then plays the
        // whole of a track that is already on disk off the server instead
        if let nextItem,
           nextItem.entryID != target?.id
               || (nextItem.streaming && fileStore.exists(.music, nextItem.filename)) {
            removeNextItem()
        }
        guard nextItem == nil, let target, target.id != failedNextEntryID,
              let (item, streaming) = nextPlayerItem(for: target.song),
              player.currentItem != nil, player.canInsert(item, after: nil)
        else { return }
        // armed now rather than when the item becomes current: the daemon
        // advances at the stop time, so it has to be set before it is reached
        item.forwardPlaybackEndTime = Self.stopTime(for: target.song)
        player.insert(item, after: nil)
        nextItem = NextItem(
            entryID: target.id, songID: target.song.id, filename: target.song.musicFilename,
            item: item, streaming: streaming)
        observeNextItemStatus(of: item)
        // an enqueued file is a file that is queued to play
        refreshInUse()
    }

    /// the queue row the slot behind the current track should be holding, or
    /// nil when there's nothing worth lining up
    private var nextEnqueueEntry: QueueEntry? {
        // repeat one plays the same file again & the same item can't sit in the
        // player's queue twice; the end of the track builds a fresh one instead
        guard repeatMode != .one, player.currentItem != nil else { return nil }
        return queue.next(wrapping: repeatMode == .all)
    }

    /// an item for a track that isn't the one playing: off disk when the file
    /// is there, off the server when this player streams, and nothing at all
    /// otherwise — a track with no item is just fetched when it's reached
    private func nextPlayerItem(for song: Song) -> (item: AVPlayerItem, streaming: Bool)? {
        if fileStore.exists(.music, song.musicFilename) {
            return (AVPlayerItem(url: fileStore.fileURL(.music, song.musicFilename)), false)
        }
        guard !downloadedOnly, streams, let token, let baseURL,
              let asset = StreamingAsset.make(
                .music, filename: song.musicFilename, token: token, baseURL: baseURL)
        else { return nil }
        return (AVPlayerItem(asset: asset), true)
    }

    /// where a track stops as the player wants it, or invalid when it plays
    /// through to the end of its file
    private static func stopTime(for song: Song) -> CMTime {
        let window = PlaybackWindow(duration: song.duration, start: song.start, finish: song.finish)
        guard window.stopsEarly else { return .invalid }
        return CMTime(seconds: window.end, preferredTimescale: 600)
    }

    /// empties the slot behind the current track. only ever that slot:
    /// removing the item that is playing has the same effect as advancing, so
    /// a re-point done wrong skips a track instead of changing what's next
    private func removeNextItem() {
        nextItemStatusObserver?.invalidate()
        nextItemStatusObserver = nil
        guard let next = nextItem else { return }
        nextItem = nil
        guard next.item !== player.currentItem else { return }
        player.remove(next.item)
    }

    /// an enqueued item can fail on its own — a dead link, or a file that
    /// turns out not to be playable. it isn't the track making sound, so
    /// nothing about playback changes: the slot is emptied and the track goes
    /// back to being fetched the ordinary way when the queue reaches it
    private func observeNextItemStatus(of item: AVPlayerItem) {
        nextItemStatusObserver?.invalidate()
        nextItemStatusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            // neither the item nor its error can cross into the actor
            let identity = ObjectIdentifier(item)
            let reason = item.error?.localizedDescription ?? "unknown"
            Task { @MainActor [weak self] in
                guard let self, let next = self.nextItem,
                      identity == ObjectIdentifier(next.item) else { return }
                log.error(
                    "enqueued item failed for \(next.filename, privacy: .public): \(reason, privacy: .public)")
                self.failedNextEntryID = next.entryID
                self.removeNextItem()
            }
        }
    }

    /// a track played through to its finish: count a play, then repeat it,
    /// move on, or stop depending on the repeat mode & queue position
    func handleTrackEnd() {
        // with the next track enqueued the player has already stepped onto it,
        // or is a moment from doing so; either way the queue follows it rather
        // than building a second item for a track that is already playing
        if advanceOntoNextItem(.trackEnded) { return }
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
        cancelPrefetch()
        currentTime = effectiveEnd
        updateNowPlayingPlaybackState()
    }
}
