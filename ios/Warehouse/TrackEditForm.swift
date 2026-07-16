import Foundation

/// m:ss.mmm helpers for the start & finish fields, mirroring the web app's
/// playback position formatters; trailing zeros in the millis are trimmed
enum PlaybackTimeMillis {
    static func format(_ time: TimeInterval) -> String {
        var totalMillis = Int((time * 1000).rounded())
        if totalMillis < 0 { totalMillis = 0 }
        let minutes = totalMillis / 60_000
        let seconds = totalMillis / 1000 % 60
        let millis = totalMillis % 1000
        let base = String(format: "%d:%02d", minutes, seconds)
        guard millis > 0 else { return base }
        var trimmed = String(format: "%03d", millis)
        while trimmed.hasSuffix("0") {
            trimmed.removeLast()
        }
        return "\(base).\(trimmed)"
    }

    static func parse(_ value: String) -> TimeInterval? {
        guard let match = value.wholeMatch(of: #/([0-9]+):([0-5][0-9])(?:\.([0-9]{0,3}))?/#) else {
            return nil
        }
        guard let minutes = Double(match.1), let seconds = Double(match.2) else { return nil }
        var fraction = 0.0
        if let digits = match.3, !digits.isEmpty {
            fraction = Double("0.\(digits)") ?? 0
        }
        return minutes * 60 + seconds + fraction
    }
}

/// the edit sheet's working copy of a track's editable fields, kept as the
/// strings being typed; mirrors the web app's edit track panel semantics:
/// only changed fields are submitted & sort names go stale until the next sync
struct TrackEditForm: Equatable {
    /// ratings are stored 0-100 but shown as 5 stars, like itunes
    static let ratingMultiplier = 20.0

    var name: String
    var artist: String
    var album: String
    var albumArtist: String
    var genre: String
    var year: String
    var start: String
    var finish: String
    /// in stars, 0 to 5 in half steps
    var rating: Double
    var artworkFilename: String?
    var artworkCleared = false

    init(song: Song) {
        name = song.name
        artist = song.artistName
        album = song.albumName
        albumArtist = song.albumArtistName
        genre = song.genre
        year = String(song.year)
        start = PlaybackTimeMillis.format(song.start)
        finish = PlaybackTimeMillis.format(song.finish)
        rating = Double(song.rating) / Self.ratingMultiplier
        artworkFilename = song.artworkFilename
    }

    var isNameValid: Bool { !name.isEmpty }
    var isArtistValid: Bool { !artist.isEmpty }
    var isGenreValid: Bool { !genre.isEmpty }

    var isYearValid: Bool {
        year.wholeMatch(of: #/[0-9]+/#) != nil && Int32(year) != nil
    }

    func isStartValid(duration: TimeInterval) -> Bool {
        isValidPosition(start, duration: duration)
    }

    func isFinishValid(duration: TimeInterval) -> Bool {
        isValidPosition(finish, duration: duration)
    }

    func isValid(duration: TimeInterval) -> Bool {
        isNameValid && isArtistValid && isGenreValid && isYearValid
            && isStartValid(duration: duration) && isFinishValid(duration: duration)
    }

    /// a track update with only the fields that differ from the song set;
    /// start & finish are sent as seconds
    func changedFields(from song: Song) -> TrackUpdate {
        var update = TrackUpdate()
        if name != song.name { update.name = name }
        if artist != song.artistName { update.artist = artist }
        if album != song.albumName { update.album = album }
        if albumArtist != song.albumArtistName { update.albumArtist = albumArtist }
        if genre != song.genre { update.genre = genre }
        if year != String(song.year), let year = Int32(year) { update.year = year }
        if start != PlaybackTimeMillis.format(song.start), let seconds = PlaybackTimeMillis.parse(start) {
            update.start = seconds
        }
        if finish != PlaybackTimeMillis.format(song.finish), let seconds = PlaybackTimeMillis.parse(finish) {
            update.finish = seconds
        }
        if ratingValue != song.rating { update.rating = Int32(ratingValue) }
        if artworkCleared {
            if song.artworkFilename != nil { update.artwork = "" }
        } else if let artworkFilename, artworkFilename != song.artworkFilename {
            update.artwork = artworkFilename
        }
        return update
    }

    /// a copy of the song with the edits applied; sort names are left as they
    /// were until the next sync, matching the web app
    func updatedSong(from song: Song) -> Song {
        Song(
            id: song.id,
            name: name,
            sortName: song.sortName,
            artistName: artist,
            artistSortName: song.artistSortName,
            albumArtistName: albumArtist,
            albumArtistSortName: song.albumArtistSortName,
            albumName: album,
            albumSortName: song.albumSortName,
            genre: genre,
            year: Int(year) ?? song.year,
            duration: song.duration,
            start: PlaybackTimeMillis.parse(start) ?? song.start,
            finish: PlaybackTimeMillis.parse(finish) ?? song.finish,
            discNumber: song.discNumber,
            trackNumber: song.trackNumber,
            playCount: song.playCount,
            rating: ratingValue,
            musicFilename: song.musicFilename,
            artworkFilename: artworkCleared ? nil : artworkFilename,
            addedDate: song.addedDate)
    }

    /// the stars back in 0-100 form
    private var ratingValue: Int {
        Int((rating * Self.ratingMultiplier).rounded())
    }

    private func isValidPosition(_ value: String, duration: TimeInterval) -> Bool {
        guard let seconds = PlaybackTimeMillis.parse(value) else { return false }
        return seconds < duration + 0.0005
    }
}
