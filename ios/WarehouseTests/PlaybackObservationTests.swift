import AVFoundation
import Foundation
import Testing
@testable import Warehouse

extension PlayerStoreTests {
    @Test("buffered bytes do not end startup buffering until the media clock advances")
    @MainActor
    func bufferedAudioBeforeClockStarts() async throws {
        let rig = BufferingPlayer()
        try await rig.start()
        defer { rig.store.pause() }
        rig.observations.handlers.last?(PlaybackObservationState(
            itemStatus: .readyToPlay, likelyToKeepUp: true, timeControlStatus: .playing,
            hasBufferedAudio: true, hasPlaybackProgress: false))
        #expect(rig.store.status == .buffering)
        #expect(rig.store.isPlaying)
        #expect(!rig.store.isActuallyPlaying)
        #expect(RemotePlaybackPayload(player: rig.store)?.isActuallyPlaying == false)
        try await Self.settle()
        #expect(rig.downloads.started.isEmpty)

        rig.send(keepUp: true, transport: .playing)
        try await Self.waitFor { rig.downloads.started.count == 1 }
        #expect(rig.store.status == .ready)
        #expect(rig.store.isActuallyPlaying)
        #expect(RemotePlaybackPayload(player: rig.store)?.isActuallyPlaying == true)
    }

    @Test("buffer coverage must contain audio at the requested playhead, not elsewhere in the file")
    func bufferCoverageAtOffset() {
        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
        func range(_ start: Double, _ end: Double) -> CMTimeRange {
            CMTimeRange(start: time(start), end: time(end))
        }
        let position = time(60)
        #expect(!PlaybackObservation.hasBufferedAudio(at: position, ranges: []))
        #expect(!PlaybackObservation.hasBufferedAudio(at: position, ranges: [range(60, 60)]))
        #expect(!PlaybackObservation.hasBufferedAudio(at: position, ranges: [range(0, 60)]))
        #expect(!PlaybackObservation.hasBufferedAudio(at: position, ranges: [range(0, 5), range(65, 70)]))
        #expect(PlaybackObservation.hasBufferedAudio(at: position, ranges: [range(60, 61)]))
        #expect(PlaybackObservation.hasBufferedAudio(at: position, ranges: [range(0, 5), range(59, 61)]))
        #expect(!PlaybackObservation.hasBufferedAudio(at: .invalid, ranges: [range(0, 80)]))
        #expect(!PlaybackObservation.hasBufferedAudio(at: position, ranges: [.invalid]))
    }

    @Test("an empty buffer at the seek position stays buffering even when transport reports playing")
    @MainActor
    func emptyBufferAtSeekPosition() async throws {
        let rig = BufferingPlayer()
        try await rig.start()
        defer { rig.store.pause() }
        rig.observations.handlers.last?(PlaybackObservationState(
            itemStatus: .readyToPlay, likelyToKeepUp: true, timeControlStatus: .playing,
            hasBufferedAudio: false, hasPlaybackProgress: false))
        #expect(rig.store.status == .buffering)
        #expect(!rig.store.isActuallyPlaying)
        try await Self.settle()
        #expect(rig.downloads.started.isEmpty)

        rig.send(keepUp: true, transport: .playing)
        try await Self.waitFor { rig.downloads.started.count == 1 }
        #expect(rig.store.status == .ready)
        #expect(rig.store.isActuallyPlaying)
    }

    @Test("buffer recovery without an item status change starts exactly one prefetch")
    @MainActor
    func bufferRecoveryRearmsPrefetch() async throws {
        let rig = BufferingPlayer()
        try await rig.start()
        rig.send(keepUp: false, transport: .waitingToPlayAtSpecifiedRate)
        #expect(rig.store.status != .ready)
        #expect(rig.store.isPlaying)
        #expect(!rig.store.isActuallyPlaying)
        #expect(rig.downloads.started.isEmpty)

        rig.send(keepUp: false, transport: .playing)
        #expect(rig.downloads.started.isEmpty)
        // only the keep-up prediction changes on the recovery callback.
        rig.send(keepUp: true, transport: .playing)
        rig.send(keepUp: true, transport: .playing)
        try await Self.waitFor { rig.downloads.started.count == 1 }
        #expect(rig.downloads.started == ["2.wav"])
        #expect(rig.store.status == .ready)
        #expect(rig.store.isActuallyPlaying)
    }

    @Test("a mid-track stall cancels prefetch and recovery re-arms it")
    @MainActor
    func midTrackStallAndRecovery() async throws {
        let rig = BufferingPlayer()
        try await rig.start()
        rig.send(keepUp: true, transport: .playing)
        try await Self.waitFor { rig.downloads.started.count == 1 }

        rig.send(keepUp: true, transport: .waitingToPlayAtSpecifiedRate)
        #expect(rig.store.status != .ready)
        #expect(!rig.store.isActuallyPlaying)
        #expect(rig.store.prefetchingFilename == nil)
        try await Self.waitFor { rig.downloads.cancelled == 1 }
        rig.send(keepUp: true, transport: .playing)
        try await Self.waitFor { rig.downloads.started.count == 2 }
        #expect(rig.store.status == .ready)
    }

    @Test("pausing during startup prevents recovery work and resume restarts the transport")
    @MainActor
    func pausedBufferRecoveryAndResume() async throws {
        let rig = BufferingPlayer()
        try await rig.start()
        rig.store.pause()
        rig.store.resume()
        try await Self.settle()
        #expect(rig.observations.player?.rate == 1)

        rig.store.pause()
        rig.send(keepUp: true, transport: .paused)
        rig.store.prefetchNext()
        try await Self.settle()
        #expect(!rig.store.isPlaying)
        #expect(rig.downloads.started.isEmpty)
        #expect(rig.observations.player?.rate == 0)
    }

    @Test("buffer recovery in the background waits for the foreground")
    @MainActor
    func backgroundBufferRecovery() async throws {
        let rig = BufferingPlayer()
        rig.store.setForeground(false)
        try await rig.start()
        rig.send(keepUp: true, transport: .playing)
        try await Self.settle()
        #expect(rig.downloads.started.isEmpty)
        rig.store.setForeground(true)
        try await Self.waitFor { rig.downloads.started == ["2.wav"] }
    }

    @Test("callbacks from before a skip cannot change playback or start downloads")
    @MainActor
    func staleBufferCallbacksAfterSkip() async throws {
        let rig = BufferingPlayer()
        try await rig.start()
        let stale = try #require(rig.observations.handlers.first)
        rig.store.skipToNext()
        try await Self.waitFor { rig.observations.handlers.count == 2 }
        stale(PlaybackObservationState(
            itemStatus: .readyToPlay, likelyToKeepUp: true, timeControlStatus: .playing,
            hasBufferedAudio: true, hasPlaybackProgress: true))
        stale(PlaybackObservationState(
            itemStatus: .failed, likelyToKeepUp: false, timeControlStatus: .paused,
            hasBufferedAudio: false, hasPlaybackProgress: false))
        try await Self.settle()
        #expect(rig.store.song?.id == "2")
        #expect(rig.store.status != .ready)
        #expect(rig.downloads.started.isEmpty)
        #expect(rig.observations.cancellations == 1)
    }

    @Test("platform transport observations follow actual playing, pause and resume")
    @MainActor
    func actualTransportObservations() async throws {
        let baseURL = try Self.localStreamBaseURL(containing: "1.wav")
        let (player, _, _) = Self.makeStreamingPlayer(host: UUID().uuidString, baseURL: baseURL)
        player.play([Self.song(id: "1")], token: "tok", baseURL: baseURL)
        try await Self.waitFor { player.isActuallyPlaying }
        #expect(player.status == .ready)
        player.pause()
        try await Self.waitFor { player.status == .buffering }
        #expect(!player.isActuallyPlaying)
        let pausedTime = player.currentTime
        player.resume()
        try await Self.waitFor { player.isActuallyPlaying && player.currentTime > pausedTime }
        #expect(player.status == .ready)
        player.pause()
    }

    @Test("a nonzero stream start and later seek wait for fresh media-clock progress")
    @MainActor
    func streamSeekResetsPlaybackProgress() async throws {
        let baseURL = try Self.localStreamBaseURL(containing: "1.wav")
        let (player, _, _) = Self.makeStreamingPlayer(host: UUID().uuidString, baseURL: baseURL)
        player.play([Self.edited(id: "1", start: 60)], token: "tok", baseURL: baseURL)
        defer { player.pause() }
        try await Self.waitFor { player.isActuallyPlaying }
        #expect(player.currentTime >= 60)

        player.seek(to: 120)
        try await Self.waitFor { player.status == .buffering }
        #expect(!player.isActuallyPlaying)
        try await Self.waitFor { player.isActuallyPlaying && player.currentTime > 120 }
        #expect(player.status == .ready)
    }

    @Test("audio activation interruptions preserve a pending stream start and paused intent")
    @MainActor
    func streamActivationInterruption() async throws {
        var activation: CheckedContinuation<Bool, Never>?
        let rig = BufferingPlayer(activate: { await withCheckedContinuation { activation = $0 } })
        rig.store.play(Self.songs(2), token: "tok", baseURL: rig.baseURL)
        try await Self.waitFor { activation != nil }
        rig.store.handleInterruption(Notification(
            name: AVAudioSession.interruptionNotification,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]))
        #expect(rig.store.isPlaying)
        rig.store.pause()
        activation?.resume(returning: true)
        try await Self.waitFor { rig.store.hasLoadedTrack }
        #expect(!rig.store.isPlaying)
        #expect(rig.observations.player?.rate == 0)
        #expect(rig.downloads.started.isEmpty)
    }
}

@MainActor
private final class BufferingPlayer {
    let observations = ControlledPlaybackObservation()
    let downloads = BufferingDownloads()
    let store: PlayerStore
    let baseURL = PlayerStoreTests.silentBaseURL()

    init(activate: @escaping @MainActor () async -> Bool = { true }) {
        let files = FileStore(rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        store = PlayerStore(
            fileStore: files, prefetchDownloader: downloads, streams: true,
            activateSessionForTests: activate, observePlayback: observations.start)
    }

    func start() async throws {
        store.play(PlayerStoreTests.songs(3), token: "tok", baseURL: baseURL)
        try await PlayerStoreTests.waitFor { store.hasLoadedTrack }
    }

    func send(keepUp: Bool, transport: AVPlayer.TimeControlStatus) {
        observations.handlers.last?(PlaybackObservationState(
            itemStatus: .readyToPlay, likelyToKeepUp: keepUp, timeControlStatus: transport,
            hasBufferedAudio: true, hasPlaybackProgress: true))
    }
}

@MainActor
private final class ControlledPlaybackObservation {
    var handlers: [PlaybackObservation.Handler] = []
    var player: AVQueuePlayer?
    var cancellations = 0

    func start(player: AVQueuePlayer, item: AVPlayerItem, receive: @escaping PlaybackObservation.Handler) -> () -> Void {
        self.player = player
        handlers.append(receive)
        return { self.cancellations += 1 }
    }
}

@MainActor
private final class BufferingDownloads: SingleFileDownloading {
    var started: [String] = []
    var cancelled = 0

    func download(_ kind: LibraryFileType, filename: String, token: String, baseURL: URL) async -> Bool {
        await MainActor.run { started.append(filename) }
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            await MainActor.run { cancelled += 1 }
        }
        return false
    }
}
