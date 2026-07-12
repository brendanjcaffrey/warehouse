import Foundation
import SwiftProtobuf
import Testing
@testable import Warehouse

@Suite("SyncStore")
@MainActor
struct SyncStoreTests {
    struct Env {
        let store: SyncStore
        let database: LibraryDatabase
        let fileStore: FileStore
        let metadata: LibraryMetadata
        let baseURL: URL
        let host: String
    }

    static func makeEnv(host: String, downloadRefreshInterval: TimeInterval = 5) -> Env {
        let suiteName = "SyncStoreTests-\(host)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let database = LibraryDatabase(inMemory: true)
        let fileStore = FileStore(rootURL: FileManager.default.temporaryDirectory
            .appending(path: "syncstore-tests-\(host)-\(UUID().uuidString)"))
        let store = SyncStore(
            database: database, fileStore: fileStore,
            session: MockURLProtocol.makeSession(), defaults: defaults,
            downloadRefreshInterval: downloadRefreshInterval)
        return Env(
            store: store, database: database, fileStore: fileStore,
            metadata: LibraryMetadata(defaults: defaults),
            baseURL: URL(string: "https://\(host)")!, host: host)
    }

    static func makeLibrary(updateTimeNs: Int64 = 43) -> Library {
        var library = Library()

        var track1 = Track()
        track1.id = "t1"
        track1.name = "One"
        track1.musicFilename = "m1.mp3"
        track1.artworkFilename = "a1.jpg"

        var track2 = Track()
        track2.id = "t2"
        track2.name = "Two"
        track2.musicFilename = "m2.mp3"
        track2.artworkFilename = ""

        library.tracks = [track1, track2]
        library.trackUserChanges = true
        library.totalFileSize = 999
        library.updateTimeNs = updateTimeNs
        return library
    }

    /// serves version & library protos plus dummy file bytes, with optional overrides
    static func installHandler(
        host: String,
        versionNs: Int64 = 43,
        library: Library? = nil,
        failingPaths: Set<String> = [],
        error: Error? = nil
    ) throws {
        let versionData = try VersionResponse.with { $0.updateTimeNs = versionNs }.serializedData()
        let libraryData = try LibraryResponse.with { $0.library = library ?? makeLibrary() }.serializedData()

        MockURLProtocol.setHandler(forHost: host) { request in
            if let error {
                throw error
            }
            let path = request.url?.path ?? ""
            if failingPaths.contains(path) {
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }

            let body: Data
            if path == "/api/version" {
                body = versionData
            } else if path == "/api/library" {
                body = libraryData
            } else if path.hasPrefix("/music/") {
                body = Data("music:\(path)".utf8)
            } else if path.hasPrefix("/artwork/") {
                body = Data("artwork:\(path)".utf8)
            } else {
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/octet-stream"])!
            return (response, body)
        }
    }

    static func requestPaths(host: String) -> [String] {
        MockURLProtocol.requests(forHost: host).compactMap { $0.url?.path }
    }

    @Test("first sync fetches the library and downloads all files")
    func firstSyncDownloadsEverything() async throws {
        let host = "sync-first.test"
        let env = Self.makeEnv(host: host)
        try Self.installHandler(host: host)

        await env.store.sync(token: "tok", baseURL: env.baseURL)

        #expect(env.store.state == .upToDate(failedDownloads: 0))
        // no version check when nothing has been synced yet
        #expect(!Self.requestPaths(host: host).contains("/api/version"))
        #expect(Self.requestPaths(host: host).contains("/api/library"))

        #expect(try await env.database.trackCount() == 2)
        #expect(env.metadata.updateTimeNs == 43)
        #expect(env.metadata.totalFileSize == 999)
        #expect(env.metadata.trackUserChanges)

        #expect(env.fileStore.list(.music) == ["m1.mp3", "m2.mp3"])
        #expect(env.fileStore.list(.artwork) == ["a1.jpg"])
    }

    @Test("sync skips the library fetch when the version matches")
    func upToDateSkipsLibraryFetch() async throws {
        let host = "sync-uptodate.test"
        let env = Self.makeEnv(host: host)
        try Self.installHandler(host: host, versionNs: 43)

        // pretend a previous sync already happened
        try await env.database.replaceLibrary(with: Self.makeLibrary())
        env.metadata.updateTimeNs = 43

        await env.store.sync(token: "tok", baseURL: env.baseURL)

        #expect(env.store.state == .upToDate(failedDownloads: 0))
        let paths = Self.requestPaths(host: host)
        #expect(paths.contains("/api/version"))
        #expect(!paths.contains("/api/library"))
        // missing files still get downloaded
        #expect(env.fileStore.list(.music) == ["m1.mp3", "m2.mp3"])
    }

    @Test("sync refetches the library when the version differs")
    func newVersionTriggersResync() async throws {
        let host = "sync-newversion.test"
        let env = Self.makeEnv(host: host)
        try Self.installHandler(host: host, versionNs: 44, library: Self.makeLibrary(updateTimeNs: 44))

        try await env.database.replaceLibrary(with: Self.makeLibrary())
        env.metadata.updateTimeNs = 43

        await env.store.sync(token: "tok", baseURL: env.baseURL)

        #expect(env.store.state == .upToDate(failedDownloads: 0))
        #expect(Self.requestPaths(host: host).contains("/api/library"))
        #expect(env.metadata.updateTimeNs == 44)
    }

    @Test("sync uses the cached library when offline")
    func offlineUsesCache() async throws {
        let host = "sync-offline.test"
        let env = Self.makeEnv(host: host)
        try Self.installHandler(host: host, error: URLError(.notConnectedToInternet))

        try await env.database.replaceLibrary(with: Self.makeLibrary())
        env.metadata.updateTimeNs = 43

        await env.store.sync(token: "tok", baseURL: env.baseURL)

        #expect(env.store.state == .upToDate(failedDownloads: 0))
        // only the version check was attempted, no downloads
        #expect(Self.requestPaths(host: host) == ["/api/version"])
        #expect(env.fileStore.list(.music).isEmpty)
    }

    @Test("a no-op sync never reports transferring, so the menu stays put")
    func upToDateIsNotTransferring() async throws {
        let host = "sync-transferring.test"
        let env = Self.makeEnv(host: host)
        try Self.installHandler(host: host, versionNs: 43)

        // idle before anything happens
        #expect(!env.store.isTransferringLibrary)

        // pretend a previous sync already fetched this version
        try await env.database.replaceLibrary(with: Self.makeLibrary())
        for name in ["m1.mp3", "m2.mp3"] {
            try env.fileStore.write(.music, name, data: Data("x".utf8))
        }
        try env.fileStore.write(.artwork, "a1.jpg", data: Data("x".utf8))
        env.metadata.updateTimeNs = 43

        await env.store.sync(token: "tok", baseURL: env.baseURL)

        #expect(env.store.state == .upToDate(failedDownloads: 0))
        #expect(!env.store.isTransferringLibrary)
    }

    @Test("failed file downloads are counted but don't block the rest")
    func failedDownloadsAreCounted() async throws {
        let host = "sync-failure.test"
        let env = Self.makeEnv(host: host)
        try Self.installHandler(host: host, failingPaths: ["/music/m1.mp3"])

        await env.store.sync(token: "tok", baseURL: env.baseURL)

        #expect(env.store.state == .upToDate(failedDownloads: 1))
        #expect(env.fileStore.list(.music) == ["m2.mp3"])
        #expect(env.fileStore.list(.artwork) == ["a1.jpg"])
    }

    @Test("sync deletes files no longer referenced by any track")
    func unreferencedFilesAreDeleted() async throws {
        let host = "sync-cleanup.test"
        let env = Self.makeEnv(host: host)
        try Self.installHandler(host: host)

        try env.fileStore.write(.music, "stale.mp3", data: Data("old".utf8))
        try env.fileStore.write(.artwork, "stale.jpg", data: Data("old".utf8))

        await env.store.sync(token: "tok", baseURL: env.baseURL)

        #expect(env.store.state == .upToDate(failedDownloads: 0))
        #expect(env.fileStore.list(.music) == ["m1.mp3", "m2.mp3"])
        #expect(env.fileStore.list(.artwork) == ["a1.jpg"])
    }

    @Test("protected artwork survives cleanup even when unreferenced")
    func protectedArtworkSurvivesCleanup() async throws {
        let host = "sync-protected.test"
        let env = Self.makeEnv(host: host)
        try Self.installHandler(host: host)

        // as if an edit queued this upload & a sync reverted the reference
        try env.fileStore.write(.artwork, "queued.jpg", data: Data("new".utf8))
        try env.fileStore.write(.artwork, "stale.jpg", data: Data("old".utf8))
        env.store.protectedArtworkFilenames = { ["queued.jpg"] }

        await env.store.sync(token: "tok", baseURL: env.baseURL)

        #expect(env.store.state == .upToDate(failedDownloads: 0))
        #expect(env.fileStore.list(.artwork) == ["a1.jpg", "queued.jpg"])
    }

    @Test("the library filter trims what gets saved, downloaded and kept")
    func libraryFilterTrimsSyncedData() async throws {
        let host = "sync-filter.test"
        let env = Self.makeEnv(host: host)
        try Self.installHandler(host: host)

        // as if a deselected playlist's file was downloaded by an earlier sync
        try env.fileStore.write(.music, "m2.mp3", data: Data("old".utf8))
        env.store.libraryFilter = { library in
            var filtered = library
            filtered.tracks = library.tracks.filter { $0.id == "t1" }
            return filtered
        }

        await env.store.sync(token: "tok", baseURL: env.baseURL)

        #expect(env.store.state == .upToDate(failedDownloads: 0))
        #expect(try await env.database.trackCount() == 1)
        // the filtered-out track's file is pruned, not downloaded
        #expect(env.fileStore.list(.music) == ["m1.mp3"])
        #expect(env.fileStore.list(.artwork) == ["a1.jpg"])
        #expect(!Self.requestPaths(host: host).contains("/music/m2.mp3"))
        // the metadata still comes from the filtered library
        #expect(env.metadata.updateTimeNs == 43)
    }

    @Test("existing files are not downloaded again")
    func existingFilesAreSkipped() async throws {
        let host = "sync-skip.test"
        let env = Self.makeEnv(host: host)
        try Self.installHandler(host: host)

        let existing = Data("already here".utf8)
        try env.fileStore.write(.music, "m1.mp3", data: existing)

        await env.store.sync(token: "tok", baseURL: env.baseURL)

        #expect(env.store.state == .upToDate(failedDownloads: 0))
        #expect(!Self.requestPaths(host: host).contains("/music/m1.mp3"))
        #expect(try Data(contentsOf: env.fileStore.fileURL(.music, "m1.mp3")) == existing)
    }

    @Test("a server error message surfaces in the error state")
    func serverErrorSetsErrorState() async throws {
        let host = "sync-error.test"
        let env = Self.makeEnv(host: host)
        let errorData = try VersionResponse.with { $0.error = "database is down" }.serializedData()
        MockURLProtocol.setHandler(forHost: host) { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/octet-stream"])!
            return (response, errorData)
        }

        env.metadata.updateTimeNs = 43

        await env.store.sync(token: "tok", baseURL: env.baseURL)

        #expect(env.store.state == .error("database is down"))
    }

    @Test("check reports new data when nothing has been synced yet")
    func checkFirstRunReportsNewData() async throws {
        let host = "check-first.test"
        let env = Self.makeEnv(host: host)
        try Self.installHandler(host: host)

        await env.store.checkForUpdates(token: "tok", baseURL: env.baseURL)

        #expect(env.store.state == .updateAvailable(newLibraryData: true, missingFiles: 0))
        // nothing is fetched or downloaded by a check
        #expect(Self.requestPaths(host: host).isEmpty)
    }

    @Test("check reports new data when the version differs")
    func checkNewVersionReportsNewData() async throws {
        let host = "check-newversion.test"
        let env = Self.makeEnv(host: host)
        try Self.installHandler(host: host, versionNs: 44)

        env.metadata.updateTimeNs = 43

        await env.store.checkForUpdates(token: "tok", baseURL: env.baseURL)

        #expect(env.store.state == .updateAvailable(newLibraryData: true, missingFiles: 0))
        #expect(Self.requestPaths(host: host) == ["/api/version"])
    }

    @Test("check reports missing files even when the library is current")
    func checkReportsMissingFiles() async throws {
        let host = "check-missing.test"
        let env = Self.makeEnv(host: host)
        try Self.installHandler(host: host, versionNs: 43)

        try await env.database.replaceLibrary(with: Self.makeLibrary())
        env.metadata.updateTimeNs = 43

        await env.store.checkForUpdates(token: "tok", baseURL: env.baseURL)

        // two music files and one artwork file are referenced but not downloaded
        #expect(env.store.state == .updateAvailable(newLibraryData: false, missingFiles: 3))
        #expect(Self.requestPaths(host: host) == ["/api/version"])
    }

    @Test("check reports up to date when the version matches and all files exist")
    func checkReportsUpToDate() async throws {
        let host = "check-uptodate.test"
        let env = Self.makeEnv(host: host)
        try Self.installHandler(host: host, versionNs: 43)

        try await env.database.replaceLibrary(with: Self.makeLibrary())
        env.metadata.updateTimeNs = 43
        try env.fileStore.write(.music, "m1.mp3", data: Data("x".utf8))
        try env.fileStore.write(.music, "m2.mp3", data: Data("x".utf8))
        try env.fileStore.write(.artwork, "a1.jpg", data: Data("x".utf8))

        await env.store.checkForUpdates(token: "tok", baseURL: env.baseURL)

        #expect(env.store.state == .upToDate(failedDownloads: 0))
    }

    @Test("check treats being offline as up to date")
    func checkOfflineReportsUpToDate() async throws {
        let host = "check-offline.test"
        let env = Self.makeEnv(host: host)
        try Self.installHandler(host: host, error: URLError(.notConnectedToInternet))

        env.metadata.updateTimeNs = 43

        await env.store.checkForUpdates(token: "tok", baseURL: env.baseURL)

        #expect(env.store.state == .upToDate(failedDownloads: 0))
    }

    @Test("completedSyncs increments when a sync finishes, not on checks")
    func completedSyncsIncrements() async throws {
        let host = "sync-completed.test"
        let env = Self.makeEnv(host: host)
        try Self.installHandler(host: host)

        #expect(env.store.completedSyncs == 0)

        await env.store.checkForUpdates(token: "tok", baseURL: env.baseURL)
        #expect(env.store.completedSyncs == 0)

        await env.store.sync(token: "tok", baseURL: env.baseURL)
        #expect(env.store.completedSyncs == 1)

        await env.store.sync(token: "tok", baseURL: env.baseURL)
        #expect(env.store.completedSyncs == 2)
    }

    @Test("download refresh ticks are throttled by the refresh interval")
    func downloadRefreshTicksAreThrottled() async throws {
        // with a zero interval, every downloaded file bumps the counter
        let eagerHost = "sync-ticks-eager.test"
        let eager = Self.makeEnv(host: eagerHost, downloadRefreshInterval: 0)
        try Self.installHandler(host: eagerHost)
        await eager.store.sync(token: "tok", baseURL: eager.baseURL)
        #expect(eager.store.downloadRefreshTicks == 3)

        // with the default interval, a fast sync never bumps it
        let throttledHost = "sync-ticks-throttled.test"
        let throttled = Self.makeEnv(host: throttledHost)
        try Self.installHandler(host: throttledHost)
        await throttled.store.sync(token: "tok", baseURL: throttled.baseURL)
        #expect(throttled.store.downloadRefreshTicks == 0)
    }

    @Test("sync hands missing files to the injected downloader")
    func injectedDownloaderReceivesMissingFiles() async throws {
        let host = "sync-injected.test"
        let suiteName = "SyncStoreTests-\(host)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let database = LibraryDatabase(inMemory: true)
        let fileStore = FileStore(rootURL: FileManager.default.temporaryDirectory
            .appending(path: "syncstore-injected-\(UUID().uuidString)"))
        let downloader = StubDownloader(failed: 1)
        let store = SyncStore(
            database: database, fileStore: fileStore,
            session: MockURLProtocol.makeSession(), defaults: defaults,
            fileDownloader: downloader)
        try Self.installHandler(host: host)

        await store.sync(token: "tok", baseURL: URL(string: "https://\(host)")!)

        // the injected downloader is used instead of the built-in one, and its
        // failure count surfaces in the final state
        #expect(Set(downloader.received) == [
            FileToDownload(type: .music, filename: "m1.mp3"),
            FileToDownload(type: .music, filename: "m2.mp3"),
            FileToDownload(type: .artwork, filename: "a1.jpg")
        ])
        #expect(store.state == .upToDate(failedDownloads: 1))
    }

    @Test("sync does nothing without a token or base url")
    func missingCredentialsDoNothing() async throws {
        let host = "sync-notoken.test"
        let env = Self.makeEnv(host: host)
        try Self.installHandler(host: host)

        await env.store.sync(token: nil, baseURL: env.baseURL)
        #expect(env.store.state == .idle)

        await env.store.sync(token: "tok", baseURL: nil)
        #expect(env.store.state == .idle)
        #expect(Self.requestPaths(host: host).isEmpty)
    }
}

/// records what it was asked to download & reports a fixed failure count, so a
/// test can confirm SyncStore routes downloads through its injected downloader
private final class StubDownloader: BulkFileDownloading, @unchecked Sendable {
    let failed: Int
    private(set) var received: [FileToDownload] = []

    init(failed: Int) {
        self.failed = failed
    }

    func downloadAll(
        _ files: [FileToDownload],
        token: String,
        baseURL: URL,
        onProgress: @escaping @MainActor @Sendable (DownloadProgress) -> Void
    ) async -> DownloadProgress {
        received = files
        let progress = DownloadProgress(completed: files.count - failed, failed: failed, total: files.count)
        await onProgress(progress)
        return progress
    }
}
