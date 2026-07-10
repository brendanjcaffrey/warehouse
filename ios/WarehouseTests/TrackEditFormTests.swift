import Foundation
import SwiftProtobuf
import Testing
@testable import Warehouse

@Suite("TrackEditForm")
struct TrackEditFormTests {
    static func song(
        name: String = "Believe",
        artist: String = "Cher",
        album: String = "Believe",
        albumArtist: String = "",
        genre: String = "Pop",
        year: Int = 1998,
        duration: TimeInterval = 240,
        start: TimeInterval = 0,
        finish: TimeInterval = 240,
        playCount: Int = 0,
        rating: Int = 0,
        artworkFilename: String? = nil
    ) -> Song {
        Song(
            id: "t1",
            name: name,
            sortName: "sort name",
            artistName: artist,
            artistSortName: "artist sort",
            albumArtistName: albumArtist,
            albumArtistSortName: "album artist sort",
            albumName: album,
            albumSortName: "album sort",
            genre: genre,
            year: year,
            duration: duration,
            start: start,
            finish: finish,
            discNumber: 1,
            trackNumber: 2,
            playCount: playCount,
            rating: rating,
            musicFilename: "t1.mp3",
            artworkFilename: artworkFilename)
    }

    @Test("format pads seconds & trims trailing millis zeros")
    func formatTimes() {
        #expect(PlaybackTimeMillis.format(0) == "0:00")
        #expect(PlaybackTimeMillis.format(65.5) == "1:05.5")
        #expect(PlaybackTimeMillis.format(7.007) == "0:07.007")
        #expect(PlaybackTimeMillis.format(7.05) == "0:07.05")
        #expect(PlaybackTimeMillis.format(200) == "3:20")
        #expect(PlaybackTimeMillis.format(59.9996) == "1:00")
    }

    @Test("parse accepts m:ss with optional millis")
    func parseTimes() throws {
        #expect(PlaybackTimeMillis.parse("0:00") == 0)
        #expect(PlaybackTimeMillis.parse("3:20") == 200)
        let withMillis = try #require(PlaybackTimeMillis.parse("1:05.5"))
        #expect(abs(withMillis - 65.5) < 0.0001)
        let padded = try #require(PlaybackTimeMillis.parse("0:07.007"))
        #expect(abs(padded - 7.007) < 0.0001)
    }

    @Test("parse rejects malformed times")
    func parseRejects() {
        #expect(PlaybackTimeMillis.parse("") == nil)
        #expect(PlaybackTimeMillis.parse("x") == nil)
        #expect(PlaybackTimeMillis.parse("1:70") == nil)
        #expect(PlaybackTimeMillis.parse("1:5") == nil)
        #expect(PlaybackTimeMillis.parse("1:05.1234") == nil)
        #expect(PlaybackTimeMillis.parse("-1:05") == nil)
        #expect(PlaybackTimeMillis.parse("1:05x") == nil)
    }

    @Test("format & parse round trip")
    func roundTrip() throws {
        for time in [0.0, 0.007, 65.5, 200.0, 3599.999] {
            let parsed = try #require(PlaybackTimeMillis.parse(PlaybackTimeMillis.format(time)))
            #expect(abs(parsed - time) < 0.0005)
        }
    }

    @Test("required fields must be non-empty & optional ones may be empty")
    func requiredFields() {
        var form = TrackEditForm(song: Self.song())
        #expect(form.isValid(duration: 240))

        form.name = ""
        #expect(!form.isNameValid)
        form.name = "x"
        form.artist = ""
        #expect(!form.isArtistValid)
        form.artist = "x"
        form.genre = ""
        #expect(!form.isGenreValid)
        form.genre = "x"

        form.album = ""
        form.albumArtist = ""
        #expect(form.isValid(duration: 240))
    }

    @Test("year must be digits that fit an int32")
    func yearValidation() {
        var form = TrackEditForm(song: Self.song())
        #expect(form.isYearValid)
        form.year = ""
        #expect(!form.isYearValid)
        form.year = "19x8"
        #expect(!form.isYearValid)
        form.year = "-5"
        #expect(!form.isYearValid)
        form.year = "99999999999"
        #expect(!form.isYearValid)
        form.year = "0"
        #expect(form.isYearValid)
    }

    @Test("start & finish must parse & stay within the duration")
    func positionValidation() {
        var form = TrackEditForm(song: Self.song(duration: 240))
        #expect(form.isStartValid(duration: 240))
        form.start = "bogus"
        #expect(!form.isStartValid(duration: 240))
        form.start = "4:01"
        #expect(!form.isStartValid(duration: 240))
        // the tolerance lets a formatted duration through despite rounding
        form.finish = "4:00"
        #expect(form.isFinishValid(duration: 240.0003))
    }

    @Test("changed fields only sets the edited fields")
    func changedFields() {
        let song = Self.song()
        var form = TrackEditForm(song: song)
        #expect(form.changedFields(from: song) == TrackUpdate())

        form.name = "Strong Enough"
        form.albumArtist = "Various Artists"
        form.year = "1999"
        form.start = "0:01.5"
        let update = form.changedFields(from: song)
        #expect(update == TrackUpdate.with {
            $0.name = "Strong Enough"
            $0.albumArtist = "Various Artists"
            $0.year = 1999
            $0.start = 1.5
        })
        #expect(!update.hasArtist)
        #expect(!update.hasFinish)
    }

    @Test("changed fields sends finish as fractional seconds")
    func changedFieldsFinish() {
        let song = Self.song(duration: 200, finish: 200)
        var form = TrackEditForm(song: song)
        form.finish = "3:19.25"
        let update = form.changedFields(from: song)
        #expect(update.hasFinish)
        #expect(abs(update.finish - 199.25) < 0.0001)
        #expect(!update.hasStart)
    }

    @Test("a changed rating is sent as its 0-100 value")
    func changedFieldsRating() {
        let song = Self.song(rating: 60)
        var form = TrackEditForm(song: song)
        #expect(form.rating == 3)
        #expect(form.changedFields(from: song) == TrackUpdate())

        form.rating = 3.5
        #expect(form.changedFields(from: song) == TrackUpdate.with { $0.rating = 70 })

        // clearing to zero still marks the field as present
        form.rating = 0
        let cleared = form.changedFields(from: song)
        #expect(cleared.hasRating)
        #expect(cleared.rating == 0)
    }

    @Test("new artwork is sent & clearing sets an empty value")
    func changedFieldsArtwork() {
        let song = Self.song(artworkFilename: "old.jpg")
        var form = TrackEditForm(song: song)
        form.artworkFilename = "new.jpg"
        #expect(form.changedFields(from: song) == TrackUpdate.with { $0.artwork = "new.jpg" })

        form = TrackEditForm(song: song)
        form.artworkCleared = true
        let cleared = form.changedFields(from: song)
        #expect(cleared.hasArtwork)
        #expect(cleared.artwork.isEmpty)

        // clearing a track that never had artwork sends nothing
        let bare = Self.song()
        form = TrackEditForm(song: bare)
        form.artworkCleared = true
        #expect(form.changedFields(from: bare) == TrackUpdate())

        // adding artwork to a bare track sends the filename
        form = TrackEditForm(song: bare)
        form.artworkFilename = "new.jpg"
        #expect(form.changedFields(from: bare) == TrackUpdate.with { $0.artwork = "new.jpg" })
    }

    @Test("updated song applies edits & leaves sort names alone")
    func updatedSong() {
        let song = Self.song(playCount: 7, rating: 40, artworkFilename: "old.jpg")
        var form = TrackEditForm(song: song)
        form.name = "Strong Enough"
        form.artist = "Cher & Friends"
        form.album = "Living Proof"
        form.albumArtist = "Various Artists"
        form.genre = "Dance"
        form.year = "2001"
        form.start = "0:01.5"
        form.finish = "3:59"
        form.rating = 4.5
        form.artworkFilename = "new.jpg"

        let updated = form.updatedSong(from: song)
        #expect(updated.id == song.id)
        #expect(updated.name == "Strong Enough")
        #expect(updated.artistName == "Cher & Friends")
        #expect(updated.albumName == "Living Proof")
        #expect(updated.albumArtistName == "Various Artists")
        #expect(updated.genre == "Dance")
        #expect(updated.year == 2001)
        #expect(abs(updated.start - 1.5) < 0.0001)
        #expect(abs(updated.finish - 239) < 0.0001)
        #expect(updated.rating == 90)
        #expect(updated.playCount == 7)
        #expect(updated.artworkFilename == "new.jpg")
        #expect(updated.sortName == song.sortName)
        #expect(updated.artistSortName == song.artistSortName)
        #expect(updated.albumArtistSortName == song.albumArtistSortName)
        #expect(updated.albumSortName == song.albumSortName)
        #expect(updated.duration == song.duration)
        #expect(updated.musicFilename == song.musicFilename)
    }

    @Test("updated song clears artwork when cleared")
    func updatedSongClearsArtwork() {
        let song = Self.song(artworkFilename: "old.jpg")
        var form = TrackEditForm(song: song)
        form.artworkCleared = true
        #expect(form.updatedSong(from: song).artworkFilename == nil)
    }
}
