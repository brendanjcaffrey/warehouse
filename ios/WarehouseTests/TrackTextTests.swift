import CoreData
import Foundation
import SwiftProtobuf
import Testing
@testable import Warehouse

@Suite("track text", .serialized)
@MainActor
struct TrackTextTests {
    static let lyrics = "\u{FEFF}first café e\u{301}\r\n第二行 🎵\n\"quoted\" \\ end\n"
    static let comments = "private notes 📝\nnext line\r\n"

    @Test("text edits are independent, preserve bytes, and distinguish clearing from no change")
    func formEdits() throws {
        var song = TrackEditFormTests.song()
        song.lyrics = Self.lyrics
        song.comments = Self.comments
        song.libraryID = "source"
        var form = TrackEditForm(song: song)
        #expect(form.lyrics == Self.lyrics && form.comments == Self.comments)
        #expect(form.changedFields(from: song) == TrackUpdate())
        form.lyrics = ""
        let clear = try TrackUpdate(serializedBytes: form.changedFields(from: song).serializedData())
        #expect(clear.hasLyrics && clear.lyrics.isEmpty && !clear.hasComments)
        form = TrackEditForm(song: song)
        form.comments = ""
        #expect(form.changedFields(from: song) == TrackUpdate.with { $0.comments = "" })
        form.lyrics = Self.comments
        let updated = form.updatedSong(from: song)
        #expect(updated.lyrics == Self.comments && updated.comments.isEmpty)
        #expect(updated.libraryID == song.libraryID)
        #expect(form.isValid(duration: song.duration))
        // discarding the working copy leaves the original track and a fresh form unchanged.
        #expect(song.lyrics == Self.lyrics && song.comments == Self.comments)
        #expect(TrackEditForm(song: song).changedFields(from: song) == TrackUpdate())
        let empty = TrackEditFormTests.song()
        #expect(TrackEditForm(song: empty).changedFields(from: empty) == TrackUpdate())
    }

    @Test("normal sync saves both fields for offline reading after database and store recreation")
    func offlineSync() async throws {
        let env = try WatchLibraryDeliveryTests.Env()
        defer { env.cleanUp() }
        let host = "text-sync.test"
        let defaults = UserDefaults(suiteName: env.root.lastPathComponent)!
        defer { defaults.removePersistentDomain(forName: env.root.lastPathComponent) }
        let files = FileStore(rootURL: env.root.appending(path: "files"))
        var library = SyncStoreTests.makeLibrary()
        library.tracks[0].lyrics = Self.lyrics
        library.tracks[0].comments = Self.comments
        library.tracks[1].comments = "unselected notes"
        try SyncStoreTests.installHandler(host: host, library: library)
        let sync = SyncStore(database: env.phone, fileStore: files, session: MockURLProtocol.makeSession(),
                             defaults: defaults, transfersFiles: false)
        let baseURL = URL(string: "https://\(host)")!
        await sync.sync(token: UpdatesStoreTests.token(), baseURL: baseURL)
        #expect(sync.state == .upToDate(failedDownloads: 0))
        WatchLibraryStoreTests.Env.close(env.phone)
        let reopened = LibraryDatabase(storeURL: env.root.appending(path: "phone.sqlite"))
        defer { WatchLibraryStoreTests.Env.close(reopened) }
        MockURLProtocol.setHandler(forHost: host) { _ in throw URLError(.notConnectedToInternet) }
        let offline = SyncStore(database: reopened, fileStore: files, session: MockURLProtocol.makeSession(),
                                defaults: defaults, transfersFiles: false)
        await offline.sync(token: UpdatesStoreTests.token(), baseURL: baseURL)
        #expect(offline.state == .offline)
        let songs = SongsStore(database: reopened, fileStore: files)
        await songs.load()
        #expect(songs.songs.first { $0.id == "t1" }.map { Data($0.lyrics.utf8) } == Data(Self.lyrics.utf8))
        #expect(songs.songs.first { $0.id == "t1" }.map { Data($0.comments.utf8) } == Data(Self.comments.utf8))
        #expect(songs.songs.first { $0.id == "t2" }?.comments == "unselected notes")
        #expect(try await reopened.songs(ids: ["t1"])["t1"]?.lyrics == Self.lyrics)
    }

    @Test("saved edits reach list and player copies and survive playback restoration")
    func editedCopies() async throws {
        let env = try WatchLibraryDeliveryTests.Env()
        defer { env.cleanUp() }
        try await env.phone.replaceLibrary(with: LibraryDatabaseTests.makeLibrary(), sourceIdentity: "source")
        let files = FileStore(rootURL: env.root.appending(path: "files"))
        let songs = SongsStore(database: env.phone, fileStore: files)
        await songs.load()
        let song = try #require(songs.songs.first)
        let player = PlaybackRestoreTests.makeQueued([song, song])
        var form = TrackEditForm(song: song)
        form.lyrics = Self.lyrics
        form.comments = Self.comments
        let edited = form.updatedSong(from: song)
        await songs.applyTrackEdit(edited)
        player.trackUpdated(edited)
        #expect(songs.errorMessage == nil)
        #expect(songs.songs.first { $0.id == song.id }?.comments == Self.comments)
        #expect(player.song?.lyrics == Self.lyrics && player.song?.comments == Self.comments)
        #expect(player.queue.upcoming.first?.song.lyrics == Self.lyrics)
        let state = PlaybackStateStore(fileURL: env.root.appending(path: "playback.json"))
        state.save(player.snapshot)
        let snapshot = try #require(state.load())
        let restored = PlayerStoreTests.makePlayer()
        restored.restore(snapshot, songs: try await env.phone.songs(ids: [song.id]), token: nil, baseURL: nil)
        #expect(restored.song?.lyrics == Self.lyrics && restored.song?.comments == Self.comments)
        form.lyrics = ""
        form.comments = ""
        await songs.applyTrackEdit(form.updatedSong(from: song))
        #expect(try await env.phone.songs(ids: [song.id])[song.id]?.lyrics.isEmpty == true)
        #expect(try await env.phone.songs(ids: [song.id])[song.id]?.comments.isEmpty == true)
    }

    @Test("multiline unicode text and explicit clears persist through failed delivery, relaunch and retry")
    func queuedText() async throws {
        let env = UpdatesStoreTests.makeEnv(host: "text-queue.test")
        defer { try? FileManager.default.removeItem(at: env.fileURL.deletingLastPathComponent()) }
        defer { env.defaults.removePersistentDomain(forName: "UpdatesStoreTests-\(env.host)") }
        env.store.configure(token: UpdatesStoreTests.token(), baseURL: env.baseURL)
        try UpdatesStoreTests.installHandler(host: env.host, success: false)
        let longLyrics = Self.lyrics + String(repeating: "long text 🎶\n", count: 20_000)
        let update = TrackUpdate.with { $0.lyrics = longLyrics; $0.comments = Self.comments }
        await env.store.addTrackUpdate(trackId: "t1", update: update, libraryID: env.identity)
        await env.store.addTrackUpdate(trackId: "t2", update: .with { $0.lyrics = "" }, libraryID: env.identity)
        let relaunched = UpdatesStoreTests.relaunch(env)
        #expect(relaunched.pending.map(\.trackUpdate) == [update, .with { $0.lyrics = "" }])
        try UpdatesStoreTests.installHandler(host: env.host)
        relaunched.configure(token: UpdatesStoreTests.token(), baseURL: env.baseURL)
        await relaunched.flush()
        let sent = try MockURLProtocol.requests(forHost: env.host).map {
            try TrackUpdate(serializedBytes: #require($0.httpBody))
        }
        try #require(sent.count == 2)
        #expect(sent == [update, .with { $0.lyrics = "" }])
        #expect(Data(sent[0].lyrics.utf8) == Data(longLyrics.utf8))
        #expect(Data(sent[0].comments.utf8) == Data(Self.comments.utf8))
        #expect(sent[1].hasLyrics && !sent[1].hasComments)
        #expect(relaunched.pending.isEmpty && UpdatesStoreTests.relaunch(env).pending.isEmpty)
    }

    @Test("pre-text persisted updates retry ordinary metadata without submitting text clears")
    func legacyUpdates() async throws {
        let env = UpdatesStoreTests.makeEnv(host: "text-legacy-queue.test")
        defer { try? FileManager.default.removeItem(at: env.fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: env.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // protobuf field one is the old name field, predating either text field.
        let json = """
        [{"type":"track","trackId":"t1","libraryID":"\(env.identity)","trackUpdate":"CgNvbGQ="}]
        """
        try Data(json.utf8).write(to: env.fileURL)
        let restored = UpdatesStoreTests.relaunch(env)
        try #require(restored.pending.count == 1)
        #expect(restored.pending[0].trackUpdate.name == "old")
        #expect(!restored.pending[0].trackUpdate.hasLyrics && !restored.pending[0].trackUpdate.hasComments)
        try UpdatesStoreTests.installHandler(host: env.host)
        restored.configure(token: UpdatesStoreTests.token(), baseURL: env.baseURL)
        await restored.flush()
        let body = try #require(MockURLProtocol.requests(forHost: env.host).first?.httpBody)
        #expect(try TrackUpdate(serializedBytes: body) == .with { $0.name = "old" })
        #expect(restored.pending.isEmpty)
    }

    @Test("text follows existing nontracking policy and refresh replacement")
    func policyAndRefresh() async throws {
        let env = UpdatesStoreTests.makeEnv(host: "text-policy.test", trackUserChanges: false)
        env.store.configure(token: UpdatesStoreTests.token(), baseURL: env.baseURL)
        #expect(!env.store.canEditTracks)
        await env.store.addTrackUpdate(trackId: "t1", update: .with { $0.lyrics = Self.lyrics }, libraryID: env.identity)
        #expect(env.store.pending.isEmpty && MockURLProtocol.requests(forHost: env.host).isEmpty)
        let database = LibraryDatabase(inMemory: true)
        var library = LibraryDatabaseTests.makeLibrary()
        library.tracks[0].lyrics = Self.lyrics
        try await database.replaceLibrary(with: library)
        var song = try #require(try await database.songs(ids: [library.tracks[0].id])[library.tracks[0].id])
        song.lyrics = "pending edit"
        try await database.updateTrack(song)
        library.tracks[0].lyrics = "server snapshot"
        try await database.replaceLibrary(with: library)
        #expect(try await database.songs(ids: [song.id])[song.id]?.lyrics == "server snapshot")
    }

    @Test("pre-text sqlite stores migrate without losing metadata, ownership or playback rows")
    func legacyStore() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let current = LibraryDatabase(inMemory: true)
        let model = try #require(current.container.managedObjectModel.copy() as? NSManagedObjectModel)
        let trackModel = try #require(model.entitiesByName["TrackEntity"])
        trackModel.properties = trackModel.properties.filter { !["lyricsData", "commentsData"].contains($0.name) }
        let url = root.appending(path: "legacy.sqlite")
        let legacy = NSPersistentContainer(name: "Library", managedObjectModel: model)
        legacy.persistentStoreDescriptions.first?.url = url
        var loadError: Error?
        legacy.loadPersistentStores { _, error in loadError = error }
        try #require(loadError == nil)
        let row = NSEntityDescription.insertNewObject(forEntityName: "TrackEntity", into: legacy.viewContext)
        row.setValue("old", forKey: "id")
        row.setValue("saved song", forKey: "name")
        row.setValue("old.mp3", forKey: "musicFilename")
        row.setValue(7, forKey: "playCount")
        try LibraryDatabase.setDocument("phoneLibraryIdentity", data: Data("source".utf8), context: legacy.viewContext)
        try legacy.viewContext.save()
        for store in legacy.persistentStoreCoordinator.persistentStores { try legacy.persistentStoreCoordinator.remove(store) }
        let migrated = LibraryDatabase(storeURL: url)
        defer { WatchLibraryStoreTests.Env.close(migrated) }
        let old = try #require(try await migrated.songs(ids: ["old"])["old"])
        #expect(old.name == "saved song" && old.playCount == 7 && old.libraryID == "source")
        #expect(old.lyrics.isEmpty && old.comments.isEmpty)
        let json = #"""
        {"queue":{"entries":[{"id":"00000000-0000-0000-0000-000000000001","songID":"old","libraryID":"source"}],
        "index":0,"contextIDs":[],"history":[],"isShuffled":false},"repeatMode":"off","currentTime":12}
        """#
        let snapshot = try JSONDecoder().decode(PlaybackSnapshot.self, from: Data(json.utf8))
        let player = PlayerStoreTests.makePlayer()
        player.restore(snapshot, songs: ["old": old], token: nil, baseURL: nil)
        #expect(player.song?.id == "old" && player.song?.lyrics.isEmpty == true)
        var edited = old
        edited.lyrics = Self.lyrics
        edited.comments = Self.comments
        try await migrated.updateTrack(edited)
        WatchLibraryStoreTests.Env.close(migrated)
        let reopened = LibraryDatabase(storeURL: url)
        defer { WatchLibraryStoreTests.Env.close(reopened) }
        #expect(try await reopened.songs(ids: ["old"])["old"]?.lyrics == Self.lyrics)
        #expect(try await reopened.songs(ids: ["old"])["old"]?.comments == Self.comments)
    }
}
