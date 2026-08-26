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

    @Test("jumping ahead records only the current track, not the skipped ones")
    func jump() {
        var queue = PlayQueue(songs: Self.songs(5))
        let jumped = queue.jump(toUpcomingIndex: 2)
        #expect(jumped)
        #expect(queue.history.map(\.song.id) == ["1"])
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

    static func renamed(_ id: String) -> Song {
        Song(
            id: id,
            name: "Renamed \(id)",
            sortName: "",
            artistName: "New Artist",
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

    @Test("updateSong refreshes every copy of the track & keeps row identity")
    func updateSong() {
        var queue = PlayQueue(songs: Self.songs(3))
        // put a second copy of song 1 in the queue & one into the history
        queue.playNext(Self.song("1"))
        queue.advance()
        #expect(queue.current?.song.id == "1")
        #expect(queue.history.map(\.song.id) == ["1"])

        let currentId = queue.current?.id
        let historyId = queue.history.first?.id
        let upcomingIds = queue.upcoming.map(\.id)

        queue.updateSong(Self.renamed("1"))

        #expect(queue.current?.song.name == "Renamed 1")
        #expect(queue.current?.id == currentId)
        #expect(queue.history.first?.song.name == "Renamed 1")
        #expect(queue.history.first?.id == historyId)
        #expect(queue.upcoming.map(\.id) == upcomingIds)
        #expect(queue.upcoming.map(\.song.name) == ["Song 2", "Song 3"])
    }

    @Test("updateSong reaches the context so unshuffling keeps the edit")
    func updateSongSurvivesUnshuffle() {
        var generator = SeededGenerator(seed: 7)
        var queue = PlayQueue(songs: Self.songs(5))
        queue.setShuffled(true, using: &generator)
        queue.updateSong(Self.renamed("2"))
        queue.setShuffled(false, using: &generator)

        #expect(queue.current?.song.id == "1")
        #expect(queue.upcoming.map(\.song.name) == ["Renamed 2", "Song 3", "Song 4", "Song 5"])
    }

    @Test("next peeks at the following entry without moving the queue")
    func nextPeeksAhead() {
        let queue = PlayQueue(songs: Self.songs(3))

        #expect(queue.next(wrapping: false)?.song.id == "2")
        #expect(queue.next(wrapping: true)?.song.id == "2")
        // peeking doesn't advance or record a play
        #expect(queue.current?.song.id == "1")
        #expect(queue.history.isEmpty)
    }

    @Test("next at the end of the queue only wraps when asked")
    func nextWrapsAtTheEnd() {
        var queue = PlayQueue(songs: Self.songs(2))
        queue.advance()

        #expect(queue.current?.song.id == "2")
        #expect(queue.next(wrapping: false) == nil)
        #expect(queue.next(wrapping: true)?.song.id == "1")
    }

    @Test("an empty queue has nothing to play next")
    func nextOnAnEmptyQueue() {
        let queue = PlayQueue(songs: [])

        #expect(queue.next(wrapping: false) == nil)
        #expect(queue.next(wrapping: true) == nil)
    }

    static func library(_ songs: [Song]) -> [String: Song] {
        Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    @Test("a stored queue comes back with its position, history & shuffle")
    func snapshotRoundTrip() {
        var generator = SeededGenerator(seed: 3)
        let songs = Self.songs(5)
        var queue = PlayQueue(songs: songs)
        queue.setShuffled(true, using: &generator)
        queue.advance()
        queue.advance()

        let restored = PlayQueue(snapshot: queue.snapshot, songs: Self.library(songs))
        #expect(restored?.current?.song.id == queue.current?.song.id)
        #expect(restored?.upcoming.map(\.song.id) == queue.upcoming.map(\.song.id))
        #expect(restored?.history.map(\.song.id) == queue.history.map(\.song.id))
        #expect(restored?.isShuffled == true)
    }

    @Test("a restored queue unshuffles back into the original order")
    func snapshotKeepsTheShuffleContext() {
        var generator = SeededGenerator(seed: 11)
        let songs = Self.songs(5)
        var queue = PlayQueue(songs: songs)
        queue.setShuffled(true, using: &generator)

        var restored = PlayQueue(snapshot: queue.snapshot, songs: Self.library(songs))
        restored?.setShuffled(false, using: &generator)
        #expect(restored?.current?.song.id == queue.current?.song.id)
        // the whole library is back in its own order around the current track
        let ids = (restored?.history.map(\.song.id) ?? []) + [restored?.current?.song.id ?? ""]
            + (restored?.upcoming.map(\.song.id) ?? [])
        #expect(ids.sorted() == songs.map(\.id).sorted())
        #expect(restored?.upcoming.map(\.song.id) == ["2", "3", "4", "5"])
    }

    @Test("the same track queued twice comes back as two rows")
    func snapshotKeepsRepeatedTracks() {
        let songs = Self.songs(2)
        var queue = PlayQueue(songs: songs)
        queue.playNext(songs[0])

        let restored = PlayQueue(snapshot: queue.snapshot, songs: Self.library(songs))
        #expect(restored?.count == 3)
        #expect(restored?.upcoming.map(\.song.id) == ["1", "2"])
        // the two rows for track 1 are still separate rows
        #expect(restored?.current?.id != restored?.upcoming.first?.id)
    }

    @Test("tracks that have left the library are dropped from a restored queue")
    func snapshotDropsMissingTracks() {
        let songs = Self.songs(4)
        let queue = PlayQueue(songs: songs, startingAt: 1)
        let remaining = songs.filter { $0.id != "3" }

        let restored = PlayQueue(snapshot: queue.snapshot, songs: Self.library(remaining))
        #expect(restored?.current?.song.id == "2")
        #expect(restored?.upcoming.map(\.song.id) == ["4"])
    }

    @Test("a queue whose current track is gone isn't restored at all")
    func snapshotWithoutItsCurrentTrack() {
        let songs = Self.songs(3)
        let queue = PlayQueue(songs: songs, startingAt: 2)

        #expect(PlayQueue(snapshot: queue.snapshot, songs: Self.library([songs[0]])) == nil)
        #expect(PlayQueue(snapshot: queue.snapshot, songs: [:]) == nil)
    }

    @Test("an empty or out of range stored queue isn't restored")
    func snapshotOutOfRange() {
        let empty = PlayQueue(songs: [])
        #expect(PlayQueue(snapshot: empty.snapshot, songs: [:]) == nil)

        let stored = PlayQueue(songs: Self.songs(2)).snapshot
        let broken = PlayQueueSnapshot(
            entries: stored.entries, index: 7, contextIDs: stored.contextIDs,
            history: stored.history, isShuffled: false)
        #expect(PlayQueue(snapshot: broken, songs: Self.library(Self.songs(2))) == nil)
    }

    @Test("a stored queue survives json")
    func snapshotEncodes() throws {
        var queue = PlayQueue(songs: Self.songs(3))
        queue.advance()

        let data = try JSONEncoder().encode(queue.snapshot)
        let decoded = try JSONDecoder().decode(PlayQueueSnapshot.self, from: data)
        #expect(decoded == queue.snapshot)
        #expect(Set(decoded.songIDs) == ["1", "2", "3"])
    }
}
