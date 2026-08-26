import Foundation

/// everything the now playing screen needs to come back after the app is
/// gone. ios suspends the app the moment it stops making sound & jettisons it
/// whenever it wants the memory back, so a player that only ever lived in
/// memory is empty every time the user opens the app after a while
struct PlaybackSnapshot: Codable, Equatable, Sendable {
    let queue: PlayQueueSnapshot
    let repeatMode: RepeatMode
    /// the playhead, so the track picks up where it was left rather than at
    /// the top. only as fresh as the last save, which is a track boundary or
    /// the app going to the background
    let currentTime: TimeInterval
}
