import Foundation
// for move(fromoffsets:tooffset:), which matches the list's onmove exactly
import SwiftUI

/// one slot in the play queue; a queue can hold the same song twice (e.g. a
/// playlist repeating a track), so rows carry their own identity
struct QueueEntry: Identifiable, Hashable, Sendable {
    let id: UUID
    let song: Song

    init(_ song: Song) {
        id = UUID()
        self.song = song
    }
}

/// the now playing list: an ordered queue with a current position plus a
/// chronological record of what's been played; previous steps backwards
/// through the queue (wrapping at the start), which isn't necessarily the
/// same as the history, so the two are kept separately
struct PlayQueue: Sendable {
    /// every played track in the order it was played, even ones skipped
    /// partway through or played more than once
    private(set) var history: [QueueEntry]
    private(set) var isShuffled: Bool
    /// the queue in play order
    private var entries: [QueueEntry]
    /// the position of the current track within the queue
    private var index: Int
    /// the context in its original order, for restoring when shuffle turns off
    private var context: [QueueEntry]

    var current: QueueEntry? {
        entries.indices.contains(index) ? entries[index] : nil
    }

    var upcoming: [QueueEntry] {
        index + 1 < entries.count ? Array(entries[(index + 1)...]) : []
    }

    /// the total number of tracks in the queue
    var count: Int { entries.count }

    /// queues the songs in order, positioned at the given one
    init(songs: [Song], startingAt start: Int = 0) {
        entries = songs.map(QueueEntry.init)
        context = entries
        index = entries.isEmpty ? 0 : max(0, min(start, entries.count - 1))
        history = []
        isShuffled = false
    }

    /// queues the songs in a random order
    init(shuffling songs: [Song], using generator: inout some RandomNumberGenerator) {
        let ordered = songs.map(QueueEntry.init)
        context = ordered
        entries = ordered.shuffled(using: &generator)
        index = 0
        history = []
        isShuffled = true
    }

    init(shuffling songs: [Song]) {
        var generator = SystemRandomNumberGenerator()
        self.init(shuffling: songs, using: &generator)
    }

    /// moves to the next track, recording the current one as played even
    /// when it was skipped partway through; wrapping continues from the last
    /// track around to the first, for the next button but not for the end of
    /// a track so playback still stops at the end of the queue
    @discardableResult
    mutating func advance(wrapping: Bool = false) -> Bool {
        guard let current, wrapping || index + 1 < entries.count else { return false }
        recordPlayed(current)
        index = index + 1 < entries.count ? index + 1 : 0
        return true
    }

    /// stays on the current track but records it as played again, for
    /// repeat one at the end of a track
    @discardableResult
    mutating func repeatCurrent() -> Bool {
        guard let current else { return false }
        recordPlayed(current)
        return true
    }

    /// moves back one queue position, wrapping around to the last track
    @discardableResult
    mutating func goBack() -> Bool {
        guard let current else { return false }
        recordPlayed(current)
        index = index == 0 ? entries.count - 1 : index - 1
        return true
    }

    /// jumps ahead to an upcoming track; only the current track counts as
    /// played, the skipped tracks in between are dropped without recording them
    @discardableResult
    mutating func jump(toUpcomingIndex upcomingIndex: Int) -> Bool {
        let target = index + 1 + upcomingIndex
        guard let current, upcomingIndex >= 0, entries.indices.contains(target) else { return false }
        recordPlayed(current)
        index = target
        return true
    }

    /// shuffles the upcoming tracks, or restores the original context order
    /// & continues from the current track's position within it
    mutating func setShuffled(_ shuffled: Bool, using generator: inout some RandomNumberGenerator) {
        guard shuffled != isShuffled else { return }
        isShuffled = shuffled
        if shuffled {
            guard index + 1 < entries.count else { return }
            var tail = Array(entries[(index + 1)...])
            tail.shuffle(using: &generator)
            entries.replaceSubrange((index + 1)..., with: tail)
        } else {
            guard let current, let position = context.firstIndex(where: { $0.id == current.id }) else { return }
            entries = context
            index = position
        }
    }

    mutating func setShuffled(_ shuffled: Bool) {
        var generator = SystemRandomNumberGenerator()
        setShuffled(shuffled, using: &generator)
    }

    /// reorders the upcoming tracks, for drag & drop in the queue view
    mutating func moveUpcoming(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard current != nil else { return }
        var tail = Array(entries[(index + 1)...])
        tail.move(fromOffsets: offsets, toOffset: destination)
        entries.replaceSubrange((index + 1)..., with: tail)
    }

    /// inserts a song right after the current track; it goes into the context
    /// too so it isn't lost when shuffle turns off
    mutating func playNext(_ song: Song) {
        guard let current else { return }
        let entry = QueueEntry(song)
        entries.insert(entry, at: index + 1)
        if let position = context.firstIndex(where: { $0.id == current.id }) {
            context.insert(entry, at: position + 1)
        }
    }

    /// keeps the played record when this queue replaces an old one; the track
    /// that was playing counts as played since it was cut off partway through
    mutating func inheritHistory(from previous: PlayQueue) {
        var carried = previous.history
        if let current = previous.current {
            carried.append(QueueEntry(current.song))
        }
        history = carried + history
    }

    /// a track can be played twice, so history rows get a fresh identity
    private mutating func recordPlayed(_ entry: QueueEntry) {
        history.append(QueueEntry(entry.song))
    }
}
