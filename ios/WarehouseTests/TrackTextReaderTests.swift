import Foundation
import Testing
@testable import Warehouse

@Suite("track text readers")
struct TrackTextReaderTests {
    @Test("now playing follows playback while menu readers pin the selected track")
    func selection() throws {
        var alpha = TrackEditFormTests.song()
        alpha.libraryID = "library"
        alpha.lyrics = "first line\n第二行 🎵"
        alpha.comments = "notes\nmore notes"
        var beta = SongListBuilderTests.song(id: "beta", name: "Beta")
        beta.lyrics = "other lyrics"
        let live = TrackTextSelection.nowPlayingLyrics
        let pinned = TrackTextSelection.track(alpha, .lyrics)
        #expect(live.song(current: alpha, library: []) == alpha)
        #expect(live.song(current: beta, library: []) == beta)
        #expect(pinned.song(current: beta, library: []) == alpha)
        #expect(live.song(current: nil, library: []) == nil)
        #expect(pinned.field == .lyrics)
        #expect(TrackTextSelection.track(alpha, .comments).field.text(in: alpha) == alpha.comments)
        #expect(live.field.text(in: alpha) == alpha.lyrics)
        #expect(live.scrollID(for: alpha) != live.scrollID(for: beta))
    }

    @Test("saved edits refresh pinned text without changing scroll or an existing editor's track")
    func editedSelection() throws {
        var alpha = TrackEditFormTests.song()
        alpha.libraryID = "library"
        let selection = TrackTextSelection.track(alpha, .comments)
        let editor = try #require(selection.song(current: nil, library: []))
        var edited = alpha
        edited.comments = "saved\ncomments"
        let displayed = try #require(selection.song(current: nil, library: [edited]))
        #expect(displayed.comments == edited.comments)
        #expect(selection.scrollID(for: alpha) == selection.scrollID(for: displayed))
        var otherLibrary = edited
        otherLibrary.libraryID = "another library"
        #expect(selection.song(current: otherLibrary, library: [otherLibrary]) == alpha)
        var form = TrackEditForm(song: editor)
        form.lyrics = "edited original"
        #expect(form.updatedSong(from: editor).id == alpha.id)
        #expect(form.updatedSong(from: editor).libraryID == alpha.libraryID)
        #expect(editor.comments == alpha.comments)
        #expect(TrackTextField.lyrics.text(in: alpha).isEmpty)
        #expect(TrackTextField.comments.text(in: alpha).isEmpty)
    }

    @Test("reader selection and a captured editor retain their contracts across actual player advances and saves")
    @MainActor
    func playerChanges() async throws {
        let env = try WatchLibraryDeliveryTests.Env()
        defer { env.cleanUp() }
        try await env.phone.replaceLibrary(with: LibraryDatabaseTests.makeLibrary(), sourceIdentity: "source")
        let songs = SongsStore(database: env.phone, fileStore: FileStore(rootURL: env.root.appending(path: "files")))
        await songs.load()
        let ordered = songs.songs.sorted { $0.id < $1.id }
        let alpha = try #require(ordered.first)
        let beta = try #require(ordered.dropFirst().first)
        let player = PlaybackRestoreTests.makeQueued([alpha, beta])
        let live = TrackTextSelection.nowPlayingLyrics
        let pinned = TrackTextSelection.track(alpha, .comments)
        let editor = try #require(live.song(current: player.song, library: songs.songs))
        var form = TrackEditForm(song: editor)
        form.lyrics = "original track lyrics\nnew line"
        form.comments = "original track comments"
        player.skipToNext()
        #expect(live.song(current: player.song, library: songs.songs)?.id == beta.id)
        #expect(pinned.song(current: player.song, library: songs.songs)?.id == alpha.id)
        let updated = form.updatedSong(from: editor)
        await songs.applyTrackEdit(updated)
        player.trackUpdated(updated)
        #expect(player.song?.id == beta.id)
        #expect(player.song?.lyrics == beta.lyrics)
        #expect(pinned.song(current: player.song, library: songs.songs)?.comments == form.comments)
        player.skipToPrevious()
        #expect(live.song(current: player.song, library: songs.songs)?.lyrics == form.lyrics)
        #expect(player.song?.id == editor.id)
    }
}
