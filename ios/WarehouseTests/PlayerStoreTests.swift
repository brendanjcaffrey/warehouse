import AVFoundation
import Foundation
import MediaPlayer
import Testing
@testable import Warehouse

@Suite("PlayerStore")
struct PlayerStoreTests {
    static func song(
        id: String = "t1", name: String = "Believe", artist: String = "", album: String = "",
        artwork: String? = nil
    ) -> Song {
        Song(
            id: id,
            name: name,
            sortName: "",
            artistName: artist,
            artistSortName: "",
            albumArtistName: "",
            albumArtistSortName: "",
            albumName: album,
            albumSortName: "",
            genre: "",
            year: 0,
            duration: 240,
            start: 0,
            finish: 0,
            discNumber: 0,
            trackNumber: 0,
            musicFilename: "\(id).wav",
            artworkFilename: artwork)
    }

    static func songs(_ count: Int) -> [Song] {
        (1...count).map { song(id: "\($0)") }
    }

    /// a player backed by throwaway temp files; nothing actually plays since
    /// no music files exist, but the queue & modes work normally
    @MainActor
    static func makePlayer(onTrackPlayed: (@MainActor (String) -> Void)? = nil) -> PlayerStore {
        let fileStore = FileStore(
            rootURL: FileManager.default.temporaryDirectory
                .appending(path: "player-tests-files-\(UUID().uuidString)"))
        return PlayerStore(fileStore: fileStore, onTrackPlayed: onTrackPlayed)
    }

    /// a player wired to a mock server that answers every file request with a
    /// little data, so on-demand downloads succeed without the network
    @MainActor
    static func makePlayerWithServer(host: String) -> (PlayerStore, FileStore, URL) {
        let baseURL = URL(string: "https://\(host)")!
        MockURLProtocol.setHandler(forHost: host) { _ in
            (HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.musicBytes)
        }
        let fileStore = FileStore(
            rootURL: FileManager.default.temporaryDirectory
                .appending(path: "player-tests-files-\(UUID().uuidString)"))
        var client = LibraryClient()
        client.session = MockURLProtocol.makeSession()
        let player = PlayerStore(fileStore: fileStore, client: client)
        return (player, fileStore, baseURL)
    }

    /// a player wired to a mock server driven by the given handler, so a test
    /// can make one file slow or make it fail; the retry a failed fetch gets
    /// is squeezed down so the failure paths don't wait a second at a time.
    /// a missed prefetch keeps the real delay unless a test asks for its retry
    @MainActor
    static func makePlayer(
        host: String,
        retryDelay: TimeInterval = 0.01,
        prefetchRetryDelay: TimeInterval = 30,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> (PlayerStore, FileStore, URL) {
        let baseURL = URL(string: "https://\(host)")!
        MockURLProtocol.setHandler(forHost: host, handler)
        let fileStore = FileStore(
            rootURL: FileManager.default.temporaryDirectory
                .appending(path: "player-tests-files-\(UUID().uuidString)"))
        var client = LibraryClient()
        client.session = MockURLProtocol.makeSession()
        let player = PlayerStore(
            fileStore: fileStore, client: client, retryDelay: retryDelay,
            prefetchRetryDelay: prefetchRetryDelay)
        return (player, fileStore, baseURL)
    }

    /// a player whose audio session activation is under the test's control,
    /// standing in for the watch, where it fails until headphones are on
    @MainActor
    static func makePlayerWithoutOutput(
        host: String, output: AudioOutput
    ) -> (PlayerStore, FileStore, URL) {
        let baseURL = URL(string: "https://\(host)")!
        MockURLProtocol.setHandler(forHost: host) { request in
            (Self.okResponse(request.url!), Self.musicBytes)
        }
        let fileStore = FileStore(
            rootURL: FileManager.default.temporaryDirectory
                .appending(path: "player-tests-files-\(UUID().uuidString)"))
        var client = LibraryClient()
        client.session = MockURLProtocol.makeSession()
        let player = PlayerStore(
            fileStore: fileStore, client: client, retryDelay: 0.01,
            activateSessionForTests: { output.isConnected })
        return (player, fileStore, baseURL)
    }

    /// a real, playable file for the mock server to hand back. the player now
    /// drops an item avfoundation won't load, so "music-bytes" would fail every
    /// track in here; this is silence, but it is silence in a format it takes.
    /// long enough that no test reaches the end of it & plays on to the next
    static let musicBytes: Data = wav(seconds: 30)

    /// 8khz 16 bit mono pcm, built by hand so the tests carry no fixture file
    static func wav(seconds: Double) -> Data {
        let sampleRate = 8000
        let bytes = Int(Double(sampleRate) * seconds) * 2
        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        ascii("RIFF")
        u32(UInt32(36 + bytes))
        ascii("WAVE")
        ascii("fmt ")
        u32(16)
        u16(1)
        u16(1)
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))
        u16(2)
        u16(16)
        ascii("data")
        u32(UInt32(bytes))
        data.append(Data(count: bytes))
        return data
    }

    static func okResponse(_ url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    /// spins until the condition holds or the attempts run out, so tests wait
    /// on the download actually landing rather than on a fixed sleep
    @MainActor
    static func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// gives an in-flight fetch a moment to land, for asserting it did not
    static func settle() async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    static func requested(_ host: String, _ filename: String) -> Bool {
        MockURLProtocol.requests(forHost: host).contains { $0.url?.lastPathComponent == filename }
    }

    static func interruption(
        _ type: AVAudioSession.InterruptionType,
        options: AVAudioSession.InterruptionOptions = []
    ) -> Notification {
        Notification(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
            AVAudioSessionInterruptionTypeKey: type.rawValue,
            AVAudioSessionInterruptionOptionKey: options.rawValue
        ])
    }

    static func routeChange(_ reason: AVAudioSession.RouteChangeReason) -> Notification {
        Notification(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: [
            AVAudioSessionRouteChangeReasonKey: reason.rawValue
        ])
    }

    @Test("playing a song that isn't downloaded fetches it to disk first")
    @MainActor
    func onDemandDownload() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, fileStore, baseURL) = Self.makePlayerWithServer(host: host)

        let song = Self.song()
        #expect(!fileStore.exists(.music, song.musicFilename))
        player.play([song], token: "tok", baseURL: baseURL)

        // wait for the background download to land the file
        for _ in 0..<200 where !fileStore.exists(.music, song.musicFilename) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(fileStore.exists(.music, song.musicFilename))

        let requests = MockURLProtocol.requests(forHost: host)
        #expect(requests.first?.url?.path == "/music/\(song.musicFilename)")
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test("an interruption pauses playback & resumes when told to")
    @MainActor
    func interruptionPausesAndResumes() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, _, baseURL) = Self.makePlayerWithServer(host: host)
        player.play([Self.song()], token: "tok", baseURL: baseURL)
        // an interruption only pauses a track that is actually playing, so
        // let the download land first
        try await Self.waitFor { player.status == .ready }
        #expect(player.isPlaying)

        player.handleInterruption(Self.interruption(.began))
        #expect(!player.isPlaying)

        // ended without shouldResume leaves it paused
        player.handleInterruption(Self.interruption(.ended))
        #expect(!player.isPlaying)

        // ended with shouldResume starts it again
        player.handleInterruption(Self.interruption(.ended, options: .shouldResume))
        #expect(player.isPlaying)
    }

    @Test("an interruption while a track is downloading doesn't cancel the start")
    @MainActor
    func interruptionDuringFetchKeepsThePendingStart() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, _, baseURL) = Self.makePlayerWithServer(host: host)

        player.play([Self.song()], token: "tok", baseURL: baseURL)
        #expect(player.status == .fetching)
        // watchos raises one of these as the audio session activates for a
        // bluetooth output, which is while the file is still coming down
        player.handleInterruption(Self.interruption(.began))

        // the download lands into a track that starts, not one sitting at a
        // play button waiting to be tapped a second time
        try await Self.waitFor { player.status == .ready }
        #expect(player.status == .ready)
        #expect(player.isPlaying)
        #expect(player.hasLoadedTrack)
    }

    @Test("play during a download restores the intent without starting the last track")
    @MainActor
    func resumeDuringFetchWaitsForTheDownload() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        // track 2 is slow enough to still be coming down while the test plays
        // with the transport
        let (player, _, baseURL) = Self.makePlayer(host: host) { request in
            if request.url?.lastPathComponent == "2.wav" {
                Thread.sleep(forTimeInterval: 1.5)
            }
            return (Self.okResponse(request.url!), Self.musicBytes)
        }

        player.play(Self.songs(2), token: "tok", baseURL: baseURL)
        try await Self.waitFor { player.status == .ready }
        player.skipToNext()
        #expect(player.song?.id == "2")
        #expect(player.status == .fetching)
        // track 1's item is still in the player until track 2's file lands
        #expect(player.hasLoadedTrack)

        player.pause()
        #expect(!player.isPlaying)
        player.resume()
        #expect(player.isPlaying)
        #expect(player.status == .fetching)

        // longer than the time observer's interval, so track 1 playing on
        // under track 2's name would have moved the playhead by now
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(player.status == .fetching)
        #expect(player.currentTime == 0)

        try await Self.waitFor { player.status == .ready }
        #expect(player.song?.id == "2")
        #expect(player.isPlaying)
    }

    @Test("unplugging headphones pauses, other route changes don't")
    @MainActor
    func routeChangePausesOnUnplug() {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, _, baseURL) = Self.makePlayerWithServer(host: host)
        player.play([Self.song()], token: "tok", baseURL: baseURL)
        #expect(player.isPlaying)

        // a new device appearing shouldn't pause
        player.handleRouteChange(Self.routeChange(.newDeviceAvailable))
        #expect(player.isPlaying)

        // the old device going away (headphones out) pauses
        player.handleRouteChange(Self.routeChange(.oldDeviceUnavailable))
        #expect(!player.isPlaying)
    }

    @Test("now playing info carries title, duration & initial state")
    func nowPlayingInfo() {
        let song = Self.song(artist: "Cher", album: "Believe")
        let info = PlayerStore.baseNowPlayingInfo(for: song, duration: 123)

        #expect(info[MPMediaItemPropertyTitle] as? String == "Believe")
        #expect(info[MPMediaItemPropertyArtist] as? String == "Cher")
        #expect(info[MPMediaItemPropertyAlbumTitle] as? String == "Believe")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? TimeInterval == 123)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval == 0)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.0)
    }

    @Test("empty artist & album are left off the lock screen")
    func emptyFields() {
        let info = PlayerStore.baseNowPlayingInfo(for: Self.song(), duration: 240)

        #expect(info[MPMediaItemPropertyTitle] as? String == "Believe")
        #expect(info[MPMediaItemPropertyArtist] == nil)
        #expect(info[MPMediaItemPropertyAlbumTitle] == nil)
    }

    @Test("shuffling a source repeats the playlist, playing normally doesn't")
    @MainActor
    func repeatModeFollowsSource() {
        let player = Self.makePlayer()
        player.playShuffled(Self.songs(3), token: nil, baseURL: nil)
        #expect(player.repeatMode == .all)
        player.play(Self.songs(3), token: nil, baseURL: nil)
        #expect(player.repeatMode == .off)
        // playing nothing leaves the mode alone
        player.cycleRepeatMode()
        player.play([], token: nil, baseURL: nil)
        #expect(player.repeatMode == .all)
    }

    @Test("a track playing through to its finish reports a play")
    @MainActor
    func trackEndReportsPlay() {
        let played = PlayedTracks()
        let player = Self.makePlayer(onTrackPlayed: { played.ids.append($0) })
        player.play(Self.songs(2), token: nil, baseURL: nil)

        player.handleTrackEnd()
        #expect(played.ids == ["1"])

        // stopping at the end of the queue still counts the last play
        player.handleTrackEnd()
        #expect(played.ids == ["1", "2"])
    }

    @MainActor
    private final class PlayedTracks {
        var ids = [String]()
    }

    @Test("system repeat settings map onto the player's modes & back")
    func repeatTypeMapping() {
        #expect(RepeatMode(MPRepeatType.off) == .off)
        #expect(RepeatMode(MPRepeatType.all) == .all)
        #expect(RepeatMode(MPRepeatType.one) == .one)
        #expect(RepeatMode.off.repeatType == .off)
        #expect(RepeatMode.all.repeatType == .all)
        #expect(RepeatMode.one.repeatType == .one)
    }

    @Test("shuffle & repeat state is mirrored into the remote command center")
    @MainActor
    func remoteCommandModes() {
        let player = Self.makePlayer()
        let center = MPRemoteCommandCenter.shared()

        player.playShuffled(Self.songs(3), token: nil, baseURL: nil)
        #expect(center.changeShuffleModeCommand.currentShuffleType == .items)
        #expect(center.changeRepeatModeCommand.currentRepeatType == .all)

        player.setShuffled(false)
        #expect(center.changeShuffleModeCommand.currentShuffleType == .off)

        player.setRepeatMode(.one)
        #expect(center.changeRepeatModeCommand.currentRepeatType == .one)
    }

    @Test("the repeat button cycles off, repeat all & repeat one")
    @MainActor
    func repeatCycle() {
        let player = Self.makePlayer()
        #expect(player.repeatMode == .off)
        player.cycleRepeatMode()
        #expect(player.repeatMode == .all)
        player.cycleRepeatMode()
        #expect(player.repeatMode == .one)
        player.cycleRepeatMode()
        #expect(player.repeatMode == .off)
    }

    @Test("with repeat off playback stops at the end of the queue")
    @MainActor
    func trackEndRepeatOff() {
        let player = Self.makePlayer()
        player.play(Self.songs(2), token: nil, baseURL: nil)
        player.handleTrackEnd()
        #expect(player.song?.id == "2")
        player.handleTrackEnd()
        #expect(player.song?.id == "2")
        #expect(!player.isPlaying)
        #expect(player.queue.history.map(\.song.id) == ["1"])
    }

    @Test("repeat all wraps from the last track back to the first")
    @MainActor
    func trackEndRepeatAll() {
        let player = Self.makePlayer()
        player.play(Self.songs(2), startingAt: 1, token: nil, baseURL: nil)
        player.cycleRepeatMode()
        player.handleTrackEnd()
        #expect(player.song?.id == "1")
        #expect(player.queue.history.map(\.song.id) == ["2"])
    }

    @Test("with repeat off next stops playback at the last track")
    @MainActor
    func nextRepeatOff() {
        let player = Self.makePlayer()
        player.play(Self.songs(2), token: nil, baseURL: nil)
        player.skipToNext()
        #expect(player.song?.id == "2")
        player.skipToNext()
        // stays on the last track rather than wrapping back to the first
        #expect(player.song?.id == "2")
        #expect(!player.isPlaying)
    }

    @Test("repeat all wraps from the last track when hitting next")
    @MainActor
    func nextRepeatAll() {
        let player = Self.makePlayer()
        player.play(Self.songs(2), startingAt: 1, token: nil, baseURL: nil)
        player.cycleRepeatMode()
        player.skipToNext()
        #expect(player.song?.id == "1")
    }

    @Test("playing from history queues the track next & jumps straight to it")
    @MainActor
    func playFromHistory() {
        let player = Self.makePlayer()
        player.play(Self.songs(3), token: nil, baseURL: nil)
        player.handleTrackEnd()
        player.handleTrackEnd()
        // now on track 3 with 1 & 2 in the history
        #expect(player.song?.id == "3")
        #expect(player.queue.history.map(\.song.id) == ["1", "2"])

        player.playFromHistory(player.queue.history[0].song)
        #expect(player.song?.id == "1")
        // the interrupted track 3 gets recorded, the skipped ones don't repeat
        #expect(player.queue.history.map(\.song.id) == ["1", "2", "3"])
    }

    @Test("repeat one stays on the same track & counts every play")
    @MainActor
    func trackEndRepeatOne() {
        let player = Self.makePlayer()
        player.play(Self.songs(2), token: nil, baseURL: nil)
        player.cycleRepeatMode()
        player.cycleRepeatMode()
        player.handleTrackEnd()
        player.handleTrackEnd()
        #expect(player.song?.id == "1")
        #expect(player.queue.upcoming.map(\.song.id) == ["2"])
        #expect(player.queue.history.map(\.song.id) == ["1", "1"])
    }

    static func edited(
        id: String,
        name: String = "Renamed",
        start: TimeInterval = 0,
        finish: TimeInterval = 0
    ) -> Song {
        Song(
            id: id,
            name: name,
            sortName: "",
            artistName: "New Artist",
            artistSortName: "",
            albumArtistName: "",
            albumArtistSortName: "",
            albumName: "",
            albumSortName: "",
            genre: "",
            year: 0,
            duration: 240,
            start: start,
            finish: finish,
            discNumber: 0,
            trackNumber: 0,
            musicFilename: "\(id).wav",
            artworkFilename: nil)
    }

    @Test("an edit to the current track updates the song & playback window")
    @MainActor
    func trackUpdatedCurrent() {
        let player = Self.makePlayer()
        player.play(Self.songs(3), token: nil, baseURL: nil)

        player.trackUpdated(Self.edited(id: "1", start: 5, finish: 200))

        #expect(player.song?.name == "Renamed")
        #expect(player.song?.artistName == "New Artist")
        #expect(player.window == PlaybackWindow(duration: 240, start: 5, finish: 200))
    }

    @Test("an edit to another track only refreshes the queue's copy")
    @MainActor
    func trackUpdatedOther() {
        let player = Self.makePlayer()
        player.play(Self.songs(3), token: nil, baseURL: nil)
        let windowBefore = player.window

        player.trackUpdated(Self.edited(id: "2"))

        #expect(player.song?.name == "Believe")
        #expect(player.window == windowBefore)
        #expect(player.queue.upcoming.first?.song.name == "Renamed")
    }

    @Test("starting a track prefetches the next queue entry")
    @MainActor
    func prefetchesTheNextTrack() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, fileStore, baseURL) = Self.makePlayerWithServer(host: host)

        player.play(Self.songs(2), token: "tok", baseURL: baseURL)
        try await Self.waitFor { fileStore.exists(.music, "2.wav") }

        // the second track is on disk before it's ever reached
        #expect(fileStore.exists(.music, "2.wav"))
        #expect(player.song?.id == "1")
        #expect(player.status == .ready)
    }

    @Test("the last track of a queue has nothing to prefetch")
    @MainActor
    func doesNotPrefetchPastTheEnd() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, fileStore, baseURL) = Self.makePlayerWithServer(host: host)

        player.play([Self.song(id: "1")], token: "tok", baseURL: baseURL)
        try await Self.waitFor { fileStore.exists(.music, "1.wav") }
        try await Self.settle()

        // repeat is off, so there is no next entry to fetch
        #expect(MockURLProtocol.requests(forHost: host).count == 1)
    }

    @Test("skipping to a new queue cancels the outstanding prefetch")
    @MainActor
    func skipCancelsThePrefetch() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        // hold the prefetch open so it is still in flight when the queue changes
        let gate = DispatchSemaphore(value: 0)
        let (player, fileStore, baseURL) = Self.makePlayer(host: host) { request in
            if request.url?.lastPathComponent == "2.wav" {
                gate.wait()
            }
            return (Self.okResponse(request.url!), Self.musicBytes)
        }

        player.play(Self.songs(3), token: "tok", baseURL: baseURL)
        try await Self.waitFor { Self.requested(host, "2.wav") }
        #expect(Self.requested(host, "2.wav"))

        player.play([Self.song(id: "9")], token: "tok", baseURL: baseURL)
        gate.signal()
        try await Self.waitFor { fileStore.exists(.music, "9.wav") }
        try await Self.settle()

        // the superseded prefetch neither lands nor takes over playback
        #expect(player.song?.id == "9")
        #expect(!fileStore.exists(.music, "2.wav"))
    }

    @Test("a failed prefetch leaves the playing track alone")
    @MainActor
    func prefetchFailureIsSilent() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, fileStore, baseURL) = Self.makePlayer(host: host) { request in
            if request.url?.lastPathComponent == "2.wav" {
                throw URLError(.notConnectedToInternet)
            }
            return (Self.okResponse(request.url!), Self.musicBytes)
        }

        player.play(Self.songs(2), token: "tok", baseURL: baseURL)
        try await Self.waitFor { Self.requested(host, "2.wav") }
        try await Self.settle()

        #expect(!fileStore.exists(.music, "2.wav"))
        #expect(player.song?.id == "1")
        #expect(player.isPlaying)
        #expect(player.status == .ready)
    }

    @Test("a prefetch that misses is tried again while the track is still playing")
    @MainActor
    func prefetchIsRetriedMidTrack() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let failOnce = Self.FailOnce()
        let (player, fileStore, baseURL) = Self.makePlayer(
            host: host, prefetchRetryDelay: 0.05
        ) { request in
            if request.url?.lastPathComponent == "2.wav", failOnce.shouldFail() {
                throw URLError(.timedOut)
            }
            return (Self.okResponse(request.url!), Self.musicBytes)
        }

        player.play(Self.songs(2), token: "tok", baseURL: baseURL)
        // the first attempt missed, so the file is only here because a second
        // one went out for it part way through the current track
        try await Self.waitFor { fileStore.exists(.music, "2.wav") }
        #expect(fileStore.exists(.music, "2.wav"))

        // & the track playing is untouched by the miss
        #expect(player.song?.id == "1")
        #expect(player.isPlaying)
        #expect(player.status == .ready)
    }

    @Test("leaving repeat one starts a prefetch for the next track")
    @MainActor
    func leavingRepeatOnePrefetches() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        // the prefetch armed as the queue starts misses, so the only way the
        // file can land is a later re-arm
        let failOnce = Self.FailOnce()
        let (player, fileStore, baseURL) = Self.makePlayer(host: host) { request in
            if request.url?.lastPathComponent == "2.wav", failOnce.shouldFail() {
                throw URLError(.notConnectedToInternet)
            }
            return (Self.okResponse(request.url!), Self.musicBytes)
        }

        player.play(Self.songs(2), token: "tok", baseURL: baseURL)
        try await Self.waitFor { Self.requested(host, "2.wav") }

        player.setRepeatMode(.one)
        try await Self.settle()
        // repeat one plays the same file again, so there is nothing to pull
        #expect(!fileStore.exists(.music, "2.wav"))

        player.setRepeatMode(.off)
        try await Self.waitFor { fileStore.exists(.music, "2.wav") }
        #expect(fileStore.exists(.music, "2.wav"))
        #expect(player.song?.id == "1")
    }

    @Test("playing a track next re-points the prefetch at it")
    @MainActor
    func playNextRepointsThePrefetch() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        // hold the prefetch of the old next track open so it is still in
        // flight when the new one is inserted ahead of it
        let gate = DispatchSemaphore(value: 0)
        let (player, fileStore, baseURL) = Self.makePlayer(host: host) { request in
            if request.url?.lastPathComponent == "2.wav" {
                gate.wait()
            }
            return (Self.okResponse(request.url!), Self.musicBytes)
        }

        player.play(Self.songs(3), token: "tok", baseURL: baseURL)
        try await Self.waitFor { Self.requested(host, "2.wav") }

        player.playNext(Self.song(id: "9"), token: "tok", baseURL: baseURL)
        gate.signal()
        try await Self.waitFor { fileStore.exists(.music, "9.wav") }
        try await Self.settle()

        #expect(player.queue.upcoming.first?.song.id == "9")
        #expect(fileStore.exists(.music, "9.wav"))
        // the prefetch of the track that used to be next was cancelled
        #expect(!fileStore.exists(.music, "2.wav"))
        #expect(player.song?.id == "1")
    }

    @Test("reordering the upcoming tracks re-points the prefetch")
    @MainActor
    func moveUpcomingRepointsThePrefetch() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, fileStore, baseURL) = Self.makePlayerWithServer(host: host)

        player.play(Self.songs(3), token: "tok", baseURL: baseURL)
        try await Self.waitFor { fileStore.exists(.music, "2.wav") }

        player.moveUpcoming(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        try await Self.waitFor { fileStore.exists(.music, "3.wav") }
        #expect(player.queue.upcoming.first?.song.id == "3")
        #expect(fileStore.exists(.music, "3.wav"))
    }

    @Test("re-arming the prefetch with the next track on disk asks for nothing")
    @MainActor
    func reArmingWithTheNextTrackCachedIsFree() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, fileStore, baseURL) = Self.makePlayerWithServer(host: host)

        player.play(Self.songs(2), token: "tok", baseURL: baseURL)
        try await Self.waitFor { fileStore.exists(.music, "2.wav") }
        let requests = MockURLProtocol.requests(forHost: host).count

        player.prefetchNext()
        player.prefetchNext()
        try await Self.settle()

        // the current track & the next one, and nothing from the re-arms
        #expect(requests == 2)
        #expect(MockURLProtocol.requests(forHost: host).count == requests)
    }

    @Test("re-arming the prefetch doesn't restart one already in flight")
    @MainActor
    func reArmingLeavesAnInFlightPrefetchAlone() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let gate = DispatchSemaphore(value: 0)
        let (player, fileStore, baseURL) = Self.makePlayer(host: host) { request in
            if request.url?.lastPathComponent == "2.wav" {
                gate.wait()
            }
            return (Self.okResponse(request.url!), Self.musicBytes)
        }

        player.play(Self.songs(2), token: "tok", baseURL: baseURL)
        try await Self.waitFor { Self.requested(host, "2.wav") }

        player.prefetchNext()
        player.prefetchNext()
        try await Self.settle()
        gate.signal()
        try await Self.waitFor { fileStore.exists(.music, "2.wav") }
        try await Self.settle()

        // the transfer that was already running finished, rather than being
        // cancelled & started over from nothing
        #expect(fileStore.exists(.music, "2.wav"))
        let requests = MockURLProtocol.requests(forHost: host)
            .filter { $0.url?.lastPathComponent == "2.wav" }
        #expect(requests.count == 1)
    }

    @Test("an uncached track with no credentials is unavailable, not stuck")
    @MainActor
    func uncachedWithoutCredentialsIsUnavailable() {
        let player = Self.makePlayer()

        player.play([Self.song()], token: nil, baseURL: nil)

        #expect(player.status == .unavailable)
        #expect(!player.isPlaying)
    }

    @Test("an uncached track the server can't supply is unavailable")
    @MainActor
    func uncachedWithoutNetworkIsUnavailable() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, _, baseURL) = Self.makePlayer(host: host) { _ in
            throw URLError(.notConnectedToInternet)
        }

        player.play([Self.song()], token: "tok", baseURL: baseURL)
        // the download is awaited, so the ui has something to show meanwhile
        #expect(player.status == .fetching)

        try await Self.waitFor { player.status != .fetching }
        #expect(player.status == .unavailable)
        #expect(!player.isPlaying)
    }

    /// flips a mock server from failing to serving, shared with the handler
    /// which runs off the main actor
    final class Offline: @unchecked Sendable {
        private let lock = NSLock()
        private var down = true

        var isDown: Bool {
            lock.lock()
            defer { lock.unlock() }
            return down
        }

        func recover() {
            lock.lock()
            defer { lock.unlock() }
            down = false
        }
    }

    @Test("a track the server can't supply doesn't leave the last one loaded to resume")
    @MainActor
    func failedFetchDropsThePreviousTrack() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, fileStore, baseURL) = Self.makePlayer(host: host) { request in
            if request.url?.lastPathComponent == "2.wav" {
                throw URLError(.notConnectedToInternet)
            }
            return (Self.okResponse(request.url!), Self.musicBytes)
        }

        player.play(Self.songs(2), token: "tok", baseURL: baseURL)
        try await Self.waitFor { player.hasLoadedTrack }
        player.skipToNext()
        try await Self.waitFor { player.status == .unavailable }

        // track 1's item is gone, so nothing can play under track 2's title &
        // no finish of track 1's can be counted as a play of track 2
        #expect(!player.hasLoadedTrack)

        // the play button retries the fetch, which fails again & stays put.
        // the retry runs through .fetching on its way, so wait it out rather
        // than settling for a fixed moment
        player.togglePlayPause()
        #expect(player.status == .fetching)
        try await Self.waitFor { player.status != .fetching }
        #expect(player.status == .unavailable)
        #expect(!player.isPlaying)
        #expect(!player.hasLoadedTrack)
        #expect(player.song?.id == "2")
        #expect(!fileStore.exists(.music, "2.wav"))
    }

    @Test("an uncached track with no credentials doesn't leave the last one loaded either")
    @MainActor
    func uncachedWithoutCredentialsDropsThePreviousTrack() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, _, baseURL) = Self.makePlayer(host: host) { request in
            (Self.okResponse(request.url!), Self.musicBytes)
        }

        player.play([Self.song(id: "1")], token: "tok", baseURL: baseURL)
        try await Self.waitFor { player.hasLoadedTrack }

        player.play([Self.song(id: "2")], token: nil, baseURL: nil)
        #expect(player.status == .unavailable)
        #expect(!player.isPlaying)
        #expect(!player.hasLoadedTrack)
    }

    @Test("the play button retries a track once the server comes back")
    @MainActor
    func playRetriesAnUnavailableTrack() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let offline = Offline()
        let (player, fileStore, baseURL) = Self.makePlayer(host: host) { request in
            if offline.isDown {
                throw URLError(.notConnectedToInternet)
            }
            return (Self.okResponse(request.url!), Self.musicBytes)
        }

        player.play([Self.song(id: "1")], token: "tok", baseURL: baseURL)
        try await Self.waitFor { player.status == .unavailable }
        #expect(!fileStore.exists(.music, "1.wav"))

        offline.recover()
        player.togglePlayPause()
        try await Self.waitFor { player.status == .ready }

        #expect(fileStore.exists(.music, "1.wav"))
        #expect(player.hasLoadedTrack)
        #expect(player.isPlaying)
        #expect(player.song?.id == "1")
    }

    /// fails the first request it sees & serves everything after, so a test
    /// can tell a retry apart from a give-up
    final class FailOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false

        func shouldFail() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if failed { return false }
            failed = true
            return true
        }
    }

    @Test("a fetch that fails once is retried rather than given up on")
    @MainActor
    func retriesAFailedFetchOnce() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let failOnce = Self.FailOnce()
        let (player, fileStore, baseURL) = Self.makePlayer(host: host) { request in
            if failOnce.shouldFail() {
                throw URLError(.timedOut)
            }
            return (Self.okResponse(request.url!), Self.musicBytes)
        }

        player.play([Self.song(id: "1")], token: "tok", baseURL: baseURL)
        try await Self.waitFor { player.status == .ready }

        #expect(player.status == .ready)
        #expect(player.isPlaying)
        #expect(fileStore.exists(.music, "1.wav"))
        // the first request failed, so the track is only playing because a
        // second one went out for it
        #expect(MockURLProtocol.requests(forHost: host).count == 2)
    }

    @Test("a track the server can't supply is skipped, not the end of the queue")
    @MainActor
    func failedFetchSkipsToTheNextTrack() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, fileStore, baseURL) = Self.makePlayer(host: host) { request in
            if request.url?.lastPathComponent == "2.wav" {
                throw URLError(.notConnectedToInternet)
            }
            return (Self.okResponse(request.url!), Self.musicBytes)
        }

        player.play(Self.songs(3), token: "tok", baseURL: baseURL)
        try await Self.waitFor { player.hasLoadedTrack }
        player.skipToNext()

        try await Self.waitFor { player.song?.id == "3" && player.status == .ready }
        #expect(player.song?.id == "3")
        #expect(player.status == .ready)
        #expect(player.isPlaying)
        #expect(player.hasLoadedTrack)
        #expect(fileStore.exists(.music, "3.wav"))
    }

    @Test("a queue with no network gives up instead of walking every track")
    @MainActor
    func offlineQueueGivesUpAfterAFewTracks() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, _, baseURL) = Self.makePlayer(host: host) { _ in
            throw URLError(.notConnectedToInternet)
        }

        player.play(Self.songs(10), token: "tok", baseURL: baseURL)
        try await Self.waitFor { player.status == .unavailable }
        try await Self.settle()

        #expect(player.status == .unavailable)
        #expect(!player.isPlaying)
        #expect(!player.hasLoadedTrack)
        // three tracks tried, twice each, & then it stopped rather than
        // spending a request timeout on every one of the ten
        #expect(player.song?.id == "3")
        #expect(MockURLProtocol.requests(forHost: host).count == 6)
    }

    @Test("a track that starts playing resets the failure count")
    @MainActor
    func aStartedTrackResetsTheFailureCount() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        // only 3 & 6 can be fetched, so each is reached across two failures
        let (player, _, baseURL) = Self.makePlayer(host: host) { request in
            let filename = request.url?.lastPathComponent
            guard filename == "3.wav" || filename == "6.wav" else {
                throw URLError(.notConnectedToInternet)
            }
            return (Self.okResponse(request.url!), Self.musicBytes)
        }

        player.play(Self.songs(6), token: "tok", baseURL: baseURL)
        try await Self.waitFor { player.song?.id == "3" && player.status == .ready }
        #expect(player.song?.id == "3")

        // without the reset these would be the fourth & fifth failures in a
        // row and the player would give up before it ever reached 6
        player.skipToNext()
        try await Self.waitFor { player.song?.id == "6" && player.status == .ready }
        #expect(player.song?.id == "6")
        #expect(player.status == .ready)
        #expect(player.isPlaying)
    }

    @Test("pausing during a fetch that fails doesn't start the next track")
    @MainActor
    func pausingDuringAFailedFetchStaysPut() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, _, baseURL) = Self.makePlayer(host: host) { _ in
            throw URLError(.notConnectedToInternet)
        }

        player.play(Self.songs(3), token: "tok", baseURL: baseURL)
        #expect(player.status == .fetching)
        player.pause()

        try await Self.waitFor { player.status == .unavailable }
        try await Self.settle()

        // the user stopped it, so a failure isn't a reason to start something
        // else on their behalf
        #expect(player.song?.id == "1")
        #expect(player.status == .unavailable)
        #expect(!player.isPlaying)
    }

    /// stands in for the watch's artwork fetcher, recording what the now
    /// playing info asked for
    @MainActor
    final class ArtworkFetches {
        var names: [String] = []
    }

    /// a player wired to a mock server & an artwork hook, so a test can see
    /// what the now playing info tried to pull
    @MainActor
    static func makePlayer(host: String, fetches: ArtworkFetches) -> (PlayerStore, FileStore, URL) {
        let baseURL = URL(string: "https://\(host)")!
        MockURLProtocol.setHandler(forHost: host) { request in
            (Self.okResponse(request.url!), Self.musicBytes)
        }
        let fileStore = FileStore(
            rootURL: FileManager.default.temporaryDirectory
                .appending(path: "player-tests-files-\(UUID().uuidString)"))
        var client = LibraryClient()
        client.session = MockURLProtocol.makeSession()
        let player = PlayerStore(
            fileStore: fileStore, client: client,
            fetchArtwork: { filename in
                fetches.names.append(filename)
                return false
            })
        return (player, fileStore, baseURL)
    }

    @Test("a track whose artwork isn't on disk pulls it for the now playing info")
    @MainActor
    func fetchesMissingNowPlayingArtwork() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let fetches = ArtworkFetches()
        let (player, _, baseURL) = Self.makePlayer(host: host, fetches: fetches)

        player.play([Self.song(artwork: "cover.jpg")], token: "tok", baseURL: baseURL)
        try await Self.waitFor { !fetches.names.isEmpty }

        #expect(fetches.names == ["cover.jpg"])
    }

    @Test("artwork already on disk isn't fetched again")
    @MainActor
    func skipsFetchingArtworkOnDisk() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let fetches = ArtworkFetches()
        let (player, fileStore, baseURL) = Self.makePlayer(host: host, fetches: fetches)
        try fileStore.write(.artwork, "cover.jpg", data: Data("already-here".utf8))

        player.play([Self.song(artwork: "cover.jpg")], token: "tok", baseURL: baseURL)
        try await Self.settle()

        #expect(fetches.names.isEmpty)
    }

    @Test("a track with no artwork asks for nothing")
    @MainActor
    func noArtworkAsksForNothing() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let fetches = ArtworkFetches()
        let (player, _, baseURL) = Self.makePlayer(host: host, fetches: fetches)

        player.play([Self.song()], token: "tok", baseURL: baseURL)
        try await Self.settle()

        #expect(fetches.names.isEmpty)
    }

    /// a player wired to a mock server & a real bounded cache, so a test can
    /// see what a start protected rather than what it asked the cache to do
    @MainActor
    static func makePlayer(host: String, budget: FileCacheBudget) -> (PlayerStore, FileCache, URL) {
        let baseURL = URL(string: "https://\(host)")!
        MockURLProtocol.setHandler(forHost: host) { request in
            (Self.okResponse(request.url!), Self.musicBytes)
        }
        let fileStore = FileStore(
            rootURL: FileManager.default.temporaryDirectory
                .appending(path: "player-tests-files-\(UUID().uuidString)"))
        var client = LibraryClient()
        client.session = MockURLProtocol.makeSession()
        let cache = FileCache(fileStore: fileStore, budget: { _ in budget })
        let player = PlayerStore(fileStore: fileStore, client: client, fileCache: cache)
        return (player, cache, baseURL)
    }

    /// writes an artwork file of an exact size & pins its creation date, so
    /// eviction order doesn't depend on how fast the writes happen
    static func writeArtwork(_ store: FileStore, _ filename: String, created: TimeInterval) throws {
        try store.write(.artwork, filename, data: Data(count: 100))
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSince1970: created)],
            ofItemAtPath: store.fileURL(.artwork, filename).path)
    }

    @Test("starting a track holds its cover against eviction")
    @MainActor
    func holdsTheNowPlayingCoverInUse() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, cache, baseURL) = Self.makePlayer(
            host: host, budget: FileCacheBudget(music: .max, artwork: 150))
        let store = cache.fileStore
        // two covers over a budget for one, & the playing track's is the older
        // of them, so it is exactly the file eviction would reach for
        try Self.writeArtwork(store, "cover.jpg", created: 1)
        try Self.writeArtwork(store, "other.jpg", created: 500)

        player.play([Self.song(artwork: "cover.jpg")], token: "tok", baseURL: baseURL)
        try await Self.waitFor { player.status == .ready }

        // the fetch that started the track already ran an eviction pass
        #expect(cache.evict().isEmpty)
        #expect(store.list(.artwork) == ["cover.jpg", "other.jpg"])
    }

    /// a bluetooth output the test can plug in or pull out partway through,
    /// since that is all the watch's audio session activation turns on
    @MainActor
    final class AudioOutput {
        private(set) var isConnected: Bool

        init(connected: Bool = false) {
            isConnected = connected
        }

        func connect() {
            isConnected = true
        }

        func disconnect() {
            isConnected = false
        }
    }

    @Test("a track that can't activate the audio session says so instead of looking ready")
    @MainActor
    func failedActivationIsReported() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let output = AudioOutput()
        let (player, fileStore, baseURL) = Self.makePlayerWithoutOutput(host: host, output: output)

        player.play([Self.song(id: "1")], token: "tok", baseURL: baseURL)
        try await Self.waitFor { player.status != .fetching }

        #expect(player.status == .needsOutput)
        #expect(!player.isPlaying)
        #expect(!player.hasLoadedTrack)
        // the fetch is downstream of activation, so nothing was pulled either
        #expect(!fileStore.exists(.music, "1.wav"))
    }

    @Test("the play button starts the track once an output is connected")
    @MainActor
    func playRecoversAfterFailedActivation() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let output = AudioOutput()
        let (player, fileStore, baseURL) = Self.makePlayerWithoutOutput(host: host, output: output)

        player.play([Self.song(id: "1")], token: "tok", baseURL: baseURL)
        try await Self.waitFor { player.status == .needsOutput }

        // without this the tap only reached player.play() on a player holding
        // no item, which could never start anything however long you pressed
        output.connect()
        player.togglePlayPause()
        try await Self.waitFor { player.status == .ready }

        #expect(player.isPlaying)
        #expect(player.hasLoadedTrack)
        #expect(fileStore.exists(.music, "1.wav"))
    }

    @Test("a failed activation doesn't leave the previous track loaded under the new one")
    @MainActor
    func failedActivationDropsThePreviousTrack() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let output = AudioOutput(connected: true)
        let (player, _, baseURL) = Self.makePlayerWithoutOutput(host: host, output: output)

        player.play(Self.songs(2), token: "tok", baseURL: baseURL)
        try await Self.waitFor { player.hasLoadedTrack }
        #expect(player.song?.id == "1")

        // the headphones come off between the two tracks
        output.disconnect()
        player.skipToNext()
        try await Self.waitFor { player.status == .needsOutput }

        // track 1's item is gone, so a tap can't resume it under track 2's
        // title & its finish can't be counted as a play of track 2
        #expect(player.song?.id == "2")
        #expect(!player.hasLoadedTrack)
        #expect(!player.isPlaying)
    }

    @Test("a track whose file won't load is dropped from disk & the queue moves on")
    @MainActor
    func unplayableFileIsDroppedAndSkipped() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        // 1 downloads fine & is still not something avfoundation can play,
        // which is what a truncated transfer leaves behind
        let (player, fileStore, baseURL) = Self.makePlayer(host: host) { request in
            let data = request.url?.lastPathComponent == "1.wav"
                ? Data("not-audio".utf8) : Self.musicBytes
            return (Self.okResponse(request.url!), data)
        }

        player.play(Self.songs(2), token: "tok", baseURL: baseURL)
        try await Self.waitFor { player.song?.id == "2" && player.status == .ready }

        #expect(player.song?.id == "2")
        #expect(player.isPlaying)
        #expect(player.hasLoadedTrack)
        // left on disk it would short circuit every later fetch of that track,
        // so the file would never become playable again
        #expect(!fileStore.exists(.music, "1.wav"))
        #expect(fileStore.exists(.music, "2.wav"))
    }

    @Test("a queue of files that won't load gives up instead of pulling them forever")
    @MainActor
    func unplayableQueueGivesUp() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, _, baseURL) = Self.makePlayer(host: host) { request in
            (Self.okResponse(request.url!), Data("not-audio".utf8))
        }

        player.play(Self.songs(6), token: "tok", baseURL: baseURL)
        try await Self.waitFor { player.status == .unavailable }

        #expect(player.status == .unavailable)
        #expect(!player.isPlaying)
        #expect(!player.hasLoadedTrack)
        // every fetch here succeeds, so the fetch budget never opens & only a
        // budget of its own stops this walking the queue re-downloading it all
        #expect(!Self.requested(host, "6.wav"))
    }
}
