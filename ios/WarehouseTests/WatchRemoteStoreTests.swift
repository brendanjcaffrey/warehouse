import Foundation
import Testing
@testable import Warehouse

@Suite("WatchRemoteStore")
@MainActor
struct WatchRemoteStoreTests {
    final class SentCommands {
        var commands = [RemoteCommand]()
    }

    static func makeStore(sent: SentCommands) -> WatchRemoteStore {
        WatchRemoteStore(send: { sent.commands.append($0) })
    }

    static let song = RemotePlaybackPayload(
        trackId: "t1", name: "Song", artistName: "Artist", artworkFilename: nil, isPlaying: true)

    @Test("the phone's state shows once it is reachable")
    func availableWhenReachableAndPlaying() {
        let store = Self.makeStore(sent: SentCommands())
        #expect(!store.isAvailable)

        store.apply(.nowPlaying(Self.song))
        // a snapshot from a phone that has since gone is not something to
        // offer buttons for
        #expect(!store.isAvailable)

        store.setReachable(true)
        #expect(store.isAvailable)
        #expect(store.nowPlaying == Self.song)
    }

    @Test("a phone with nothing playing has nothing to remote control")
    func nothingPlayingIsNotAvailable() {
        let store = Self.makeStore(sent: SentCommands())
        store.setReachable(true)
        store.apply(.nowPlaying(Self.song))
        store.apply(.nowPlaying(nil))

        #expect(store.nowPlaying == nil)
        #expect(!store.isAvailable)
    }

    @Test("becoming reachable asks the phone what it is playing")
    func asksForStateWhenReachable() {
        let sent = SentCommands()
        let store = Self.makeStore(sent: sent)

        store.setReachable(true)
        #expect(sent.commands == [.requestState])

        // a repeated report of the same reachability doesn't ask again, which
        // is what keeps a failed send from spinning
        store.setReachable(true)
        #expect(sent.commands == [.requestState])
    }

    @Test("play pause flips the button before the phone answers")
    func playPauseUpdatesOptimistically() {
        let sent = SentCommands()
        let store = Self.makeStore(sent: sent)
        store.apply(.nowPlaying(Self.song))

        store.command(.playPause)

        #expect(store.nowPlaying?.isPlaying == false)
        #expect(sent.commands == [.playPause])
    }

    @Test("shuffle and repeat also move before the phone answers")
    func modesUpdateOptimistically() {
        let store = Self.makeStore(sent: SentCommands())
        store.apply(.nowPlaying(Self.song))

        store.command(.toggleShuffle)
        store.command(.cycleRepeat)

        #expect(store.nowPlaying?.isShuffled == true)
        #expect(store.nowPlaying?.repeatMode == .all)
    }

    @Test("the phone's answer overrides the optimistic state")
    func phoneStateWins() {
        let store = Self.makeStore(sent: SentCommands())
        store.apply(.nowPlaying(Self.song))
        store.command(.next)

        let next = RemotePlaybackPayload(
            trackId: "t2", name: "Next", artistName: "Artist", artworkFilename: nil, isPlaying: true)
        store.apply(.nowPlaying(next))

        #expect(store.nowPlaying == next)
    }

    @Test("skips don't guess which track lands")
    func skipsDoNotGuess() {
        let sent = SentCommands()
        let store = Self.makeStore(sent: sent)
        store.apply(.nowPlaying(Self.song))

        store.command(.next)
        store.command(.previous)

        #expect(store.nowPlaying == Self.song)
        #expect(sent.commands == [.next, .previous])
    }

    @Test("starting playback on the watch pauses a phone that is playing")
    func pausesPhoneWhenPlaying() {
        let sent = SentCommands()
        let store = Self.makeStore(sent: sent)
        store.apply(.nowPlaying(Self.song))

        store.pausePhone()

        #expect(sent.commands == [.pause])
        #expect(store.nowPlaying?.isPlaying == false)
    }

    @Test("a phone that is already paused or idle is left alone")
    func doesNotPauseAnIdlePhone() {
        let sent = SentCommands()
        let store = Self.makeStore(sent: sent)

        store.pausePhone()
        #expect(sent.commands.isEmpty)

        store.apply(.nowPlaying(Self.song.with(isPlaying: false)))
        store.pausePhone()
        #expect(sent.commands.isEmpty)
    }

    @Test("commands sent with nothing playing don't invent a track")
    func commandsWithoutATrack() {
        let sent = SentCommands()
        let store = Self.makeStore(sent: sent)

        store.command(.playPause)

        #expect(store.nowPlaying == nil)
        #expect(sent.commands == [.playPause])
    }
}
