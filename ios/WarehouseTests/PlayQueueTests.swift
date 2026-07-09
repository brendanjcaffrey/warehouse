import Foundation
import Testing
@testable import Warehouse

/// deterministic splitmix64 generator so shuffling is testable
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58476D1CE4E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D049BB133111EB
        return mixed ^ (mixed >> 31)
    }
}

@Suite("PlayQueue")
struct PlayQueueTests {
    static func song(_ id: String) -> Song {
        Song(
            id: id,
            name: "Song \(id)",
            sortName: "",
            artistName: "",
            artistSortName: "",
            albumArtistName: "",
            albumArtistSortName: "",
            albumName: "",
            albumSortName: "",
            genre: "",
            year: 0,
            duration: 0,
            start: 0,
            finish: 0,
            discNumber: 0,
            trackNumber: 0,
            musicFilename: "\(id).mp3",
            artworkFilename: nil)
    }

    static func songs(_ count: Int) -> [Song] {
        (1...count).map { song("\($0)") }
    }

    @Test("starting mid-list keeps the earlier songs behind the current one")
    func startPosition() {
        var queue = PlayQueue(songs: Self.songs(5), startingAt: 2)
        #expect(queue.history.isEmpty)
        #expect(queue.current?.song.id == "3")
        #expect(queue.upcoming.map(\.song.id) == ["4", "5"])
        #expect(!queue.isShuffled)
        queue.goBack()
        #expect(queue.current?.song.id == "2")
    }

    @Test("out of range start indexes clamp & empty queues have no current")
    func startEdgeCases() {
        #expect(PlayQueue(songs: Self.songs(3), startingAt: 9).current?.song.id == "3")
        #expect(PlayQueue(songs: Self.songs(3), startingAt: -1).current?.song.id == "1")

        var empty = PlayQueue(songs: [])
        #expect(empty.current == nil)
        #expect(empty.history.isEmpty)
        #expect(empty.upcoming.isEmpty)
        let wentBack = empty.goBack()
        #expect(!wentBack)
    }

    @Test("shuffling plays every song in a random order")
    func shuffledStart() {
        var generator = SeededGenerator(seed: 1)
        let queue = PlayQueue(shuffling: Self.songs(20), using: &generator)

        #expect(queue.isShuffled)
        #expect(queue.history.isEmpty)
        var ids = queue.upcoming.map(\.song.id)
        if let current = queue.current {
            ids.insert(current.song.id, at: 0)
        }
        #expect(Set(ids) == Set(Self.songs(20).map(\.id)))
        #expect(ids != Self.songs(20).map(\.id))
    }

    @Test("advancing walks the queue & records the history even when skipped")
    func advance() {
        var queue = PlayQueue(songs: Self.songs(3))
        queue.advance()
        queue.advance()
        #expect(queue.current?.song.id == "3")
        #expect(queue.history.map(\.song.id) == ["1", "2"])
        #expect(queue.upcoming.isEmpty)

        let pastEnd = queue.advance()
        #expect(!pastEnd)
        #expect(queue.current?.song.id == "3")
    }

    @Test("next wraps around to the first track when asked")
    func advanceWrapping() {
        var queue = PlayQueue(songs: Self.songs(3), startingAt: 2)
        let wrapped = queue.advance(wrapping: true)
        #expect(wrapped)
        #expect(queue.current?.song.id == "1")
        #expect(queue.upcoming.map(\.song.id) == ["2", "3"])
        #expect(queue.history.map(\.song.id) == ["3"])

        var empty = PlayQueue(songs: [])
        let advanced = empty.advance(wrapping: true)
        #expect(!advanced)
    }

    @Test("repeating the current track records the play without moving")
    func repeatCurrent() {
        var queue = PlayQueue(songs: Self.songs(2))
        let repeated = queue.repeatCurrent()
        #expect(repeated)
        #expect(queue.current?.song.id == "1")
        #expect(queue.upcoming.map(\.song.id) == ["2"])
        #expect(queue.history.map(\.song.id) == ["1"])

        var empty = PlayQueue(songs: [])
        let repeatedEmpty = empty.repeatCurrent()
        #expect(!repeatedEmpty)
    }

    @Test("previous steps backwards through the queue & wraps around")
    func goBack() {
        var queue = PlayQueue(songs: Self.songs(3))
        queue.goBack()
        #expect(queue.current?.song.id == "3")
        #expect(queue.upcoming.isEmpty)
        queue.goBack()
        #expect(queue.current?.song.id == "2")
        #expect(queue.upcoming.map(\.song.id) == ["3"])
        #expect(queue.history.map(\.song.id) == ["1", "3"])
    }

    @Test("the history records every play in order, not the queue order")
    func historyRecordsPlays() {
        var queue = PlayQueue(songs: Self.songs(2))
        queue.advance()
        queue.goBack()
        queue.advance()
        #expect(queue.history.map(\.song.id) == ["1", "2", "1"])
        // replays get distinct identities so the history list renders them all
        #expect(Set(queue.history.map(\.id)).count == 3)
    }

    @Test("play next inserts right after the current track")
    func playNext() {
        var queue = PlayQueue(songs: Self.songs(3))
        queue.playNext(Self.song("9"))
        #expect(queue.current?.song.id == "1")
        #expect(queue.upcoming.map(\.song.id) == ["9", "2", "3"])
        queue.advance()
        #expect(queue.current?.song.id == "9")

        var empty = PlayQueue(songs: [])
        empty.playNext(Self.song("9"))
        #expect(empty.current == nil)
        #expect(empty.upcoming.isEmpty)
    }

    @Test("a song queued next survives turning shuffle off")
    func playNextSurvivesUnshuffle() {
        var queue = PlayQueue(songs: Self.songs(5))
        var generator = SeededGenerator(seed: 4)
        queue.setShuffled(true, using: &generator)
        queue.playNext(Self.song("9"))
        queue.setShuffled(false, using: &generator)
        #expect(queue.current?.song.id == "1")
        #expect(queue.upcoming.map(\.song.id) == ["9", "2", "3", "4", "5"])
    }

    @Test("a replacement queue keeps the history & counts the interrupted track")
    func inheritHistory() {
        var previous = PlayQueue(songs: Self.songs(3))
        previous.advance()

        var queue = PlayQueue(songs: [Self.song("9")])
        queue.inheritHistory(from: previous)
        #expect(queue.history.map(\.song.id) == ["1", "2"])
        #expect(queue.current?.song.id == "9")

        var fresh = PlayQueue(songs: [Self.song("8")])
        fresh.inheritHistory(from: PlayQueue(songs: []))
        #expect(fresh.history.isEmpty)
    }

    @Test("jumping ahead counts the skipped tracks as played")
    func jump() {
        var queue = PlayQueue(songs: Self.songs(5))
        let jumped = queue.jump(toUpcomingIndex: 2)
        #expect(jumped)
        #expect(queue.history.map(\.song.id) == ["1", "2", "3"])
        #expect(queue.current?.song.id == "4")
        #expect(queue.upcoming.map(\.song.id) == ["5"])

        let outOfRange = queue.jump(toUpcomingIndex: 5)
        #expect(!outOfRange)
    }

    @Test("turning shuffle on shuffles only the upcoming tracks")
    func shuffleOn() {
        var queue = PlayQueue(songs: Self.songs(20), startingAt: 2)
        var generator = SeededGenerator(seed: 2)
        queue.setShuffled(true, using: &generator)

        #expect(queue.isShuffled)
        #expect(queue.current?.song.id == "3")
        let expected = (4...20).map { "\($0)" }
        #expect(Set(queue.upcoming.map(\.song.id)) == Set(expected))
        #expect(queue.upcoming.map(\.song.id) != expected)
        // the part of the queue behind the current track is untouched
        queue.goBack()
        #expect(queue.current?.song.id == "2")
    }

    @Test("turning shuffle off continues from the current track's original position")
    func shuffleOff() {
        var generator = SeededGenerator(seed: 3)
        var queue = PlayQueue(shuffling: Self.songs(10), using: &generator)
        queue.advance()
        queue.advance()

        let position = Int(queue.current!.song.id)!
        queue.setShuffled(false, using: &generator)
        #expect(!queue.isShuffled)
        #expect(queue.current?.song.id == "\(position)")
        let expected = Self.songs(10).map(\.id).filter { Int($0)! > position }
        #expect(queue.upcoming.map(\.song.id) == expected)
        // the part behind the current track follows the original order too
        queue.goBack()
        #expect(queue.current?.song.id == (position == 1 ? "10" : "\(position - 1)"))
    }

    @Test("moving upcoming tracks reorders them")
    func move() {
        var queue = PlayQueue(songs: Self.songs(5))
        queue.moveUpcoming(fromOffsets: [0], toOffset: 4)
        #expect(queue.upcoming.map(\.song.id) == ["3", "4", "5", "2"])
        #expect(queue.current?.song.id == "1")
    }

    @Test("the same song twice in a queue gets two distinct entries")
    func duplicateSongs() {
        let song = Self.song("1")
        let queue = PlayQueue(songs: [song, song])
        #expect(queue.current?.song.id == "1")
        #expect(queue.upcoming.map(\.song.id) == ["1"])
        #expect(queue.current?.id != queue.upcoming[0].id)
    }
}
