import Foundation

/// a transport command the watch sends to the phone while it is acting as a
/// remote for music coming out of the phone
enum RemoteCommand: String, Sendable, CaseIterable {
    case playPause
    case pause
    case next
    case previous
    case toggleShuffle
    case cycleRepeat
    /// asks the phone for a fresh snapshot; sent when the watch app opens or
    /// the phone comes back in range, since pushes only reach a watch that
    /// was reachable at the time
    case requestState
}

/// what the phone is playing, as much of it as the watch's remote screen
/// shows. the watch has no copy of the phone's queue, so this is the whole
/// picture it gets
struct RemotePlaybackPayload: Equatable, Sendable {
    let trackId: String
    let name: String
    let artistName: String
    let artworkFilename: String?
    let isPlaying: Bool
    let isShuffled: Bool
    let repeatMode: RepeatMode

    private static let trackIdKey = "trackId"
    private static let nameKey = "name"
    private static let artistNameKey = "artistName"
    private static let artworkFilenameKey = "artworkFilename"
    private static let isPlayingKey = "isPlaying"
    private static let isShuffledKey = "isShuffled"
    private static let repeatModeKey = "repeatMode"

    init(
        trackId: String,
        name: String,
        artistName: String,
        artworkFilename: String?,
        isPlaying: Bool,
        isShuffled: Bool = false,
        repeatMode: RepeatMode = .off
    ) {
        self.trackId = trackId
        self.name = name
        self.artistName = artistName
        self.artworkFilename = artworkFilename
        self.isPlaying = isPlaying
        self.isShuffled = isShuffled
        self.repeatMode = repeatMode
    }

    init?(dictionary: [String: Any]) {
        guard let trackId = dictionary[Self.trackIdKey] as? String,
              let name = dictionary[Self.nameKey] as? String,
              let artistName = dictionary[Self.artistNameKey] as? String,
              let isPlaying = dictionary[Self.isPlayingKey] as? Bool
        else {
            return nil
        }
        self.init(
            trackId: trackId,
            name: name,
            artistName: artistName,
            // absent for a track with no artwork
            artworkFilename: dictionary[Self.artworkFilenameKey] as? String,
            isPlaying: isPlaying,
            isShuffled: dictionary[Self.isShuffledKey] as? Bool ?? false,
            repeatMode: (dictionary[Self.repeatModeKey] as? String).flatMap(RepeatMode.init(rawValue:)) ?? .off)
    }

    func encode() -> [String: Any] {
        var dictionary: [String: Any] = [
            Self.trackIdKey: trackId,
            Self.nameKey: name,
            Self.artistNameKey: artistName,
            Self.isPlayingKey: isPlaying,
            Self.isShuffledKey: isShuffled,
            Self.repeatModeKey: repeatMode.rawValue
        ]
        if let artworkFilename {
            dictionary[Self.artworkFilenameKey] = artworkFilename
        }
        return dictionary
    }
}

/// the live messages the two apps exchange over watch connectivity: the phone
/// pushes what it is playing, the watch sends back transport commands. these
/// ride `sendMessage`, unlike the settings context & the queued plays, because
/// they are only worth anything while both apps are up
enum WatchRemoteMessage: Equatable, Sendable {
    /// nil means the phone has nothing playing
    case nowPlaying(RemotePlaybackPayload?)
    case command(RemoteCommand)

    private static let kindKey = "remoteKind"
    private static let songKey = "song"
    private static let commandKey = "command"
    private static let nowPlayingKind = "nowPlaying"
    private static let commandKind = "command"

    init?(dictionary: [String: Any]) {
        switch dictionary[Self.kindKey] as? String {
        case Self.nowPlayingKind:
            guard let song = dictionary[Self.songKey] else {
                self = .nowPlaying(nil)
                return
            }
            guard let song = song as? [String: Any],
                  let payload = RemotePlaybackPayload(dictionary: song)
            else {
                return nil
            }
            self = .nowPlaying(payload)
        case Self.commandKind:
            guard let raw = dictionary[Self.commandKey] as? String,
                  let command = RemoteCommand(rawValue: raw)
            else {
                return nil
            }
            self = .command(command)
        default:
            return nil
        }
    }

    func encode() -> [String: Any] {
        switch self {
        case .nowPlaying(let payload):
            var dictionary: [String: Any] = [Self.kindKey: Self.nowPlayingKind]
            if let payload {
                dictionary[Self.songKey] = payload.encode()
            }
            return dictionary
        case .command(let command):
            return [Self.kindKey: Self.commandKind, Self.commandKey: command.rawValue]
        }
    }
}

extension RemotePlaybackPayload {
    /// what the player is doing, as the watch's remote screen sees it; nil
    /// when nothing is loaded & there is nothing to drive
    @MainActor
    init?(player: PlayerStore) {
        guard let song = player.song else { return nil }
        self.init(
            trackId: song.id,
            name: song.name,
            artistName: song.artistName,
            artworkFilename: song.artworkFilename,
            isPlaying: player.isPlaying,
            isShuffled: player.queue.isShuffled,
            repeatMode: player.repeatMode)
    }
}

extension PlayerStore {
    /// runs a command that arrived from the watch. the phone owns the queue &
    /// the audio route, so a remote tap is the same call the phone's own
    /// buttons make
    func apply(_ command: RemoteCommand) {
        switch command {
        case .playPause:
            togglePlayPause()
        case .pause:
            pause()
        case .next:
            skipToNext()
        case .previous:
            skipToPrevious()
        case .toggleShuffle:
            setShuffled(!queue.isShuffled)
        case .cycleRepeat:
            cycleRepeatMode()
        case .requestState:
            // answered by the state that goes back, not by the player
            break
        }
    }
}
