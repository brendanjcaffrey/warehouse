import AVFoundation
import Foundation
import MediaPlayer
import Testing
@testable import Warehouse

@Suite("PlayerStore")
struct PlayerStoreTests {
    static func song(id: String = "t1", name: String = "Believe", artist: String = "", album: String = "") -> Song {
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
            musicFilename: "\(id).mp3",
            artworkFilename: nil)
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
            (HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("music-bytes".utf8))
        }
        let fileStore = FileStore(
            rootURL: FileManager.default.temporaryDirectory
                .appending(path: "player-tests-files-\(UUID().uuidString)"))
        var client = LibraryClient()
        client.session = MockURLProtocol.makeSession()
        let player = PlayerStore(fileStore: fileStore, client: client)
        return (player, fileStore, baseURL)
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
    func interruptionPausesAndResumes() {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, _, baseURL) = Self.makePlayerWithServer(host: host)
        player.play([Self.song()], token: "tok", baseURL: baseURL)
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
            musicFilename: "\(id).mp3",
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
}
