import XCTest
import PostgresNIO
import ApplicationServices

private let firstID = "0000000000000001"
private let secondID = "0000000000000002"
private let wavID = "0000000000000003"

private final class FixtureMusic: MusicTextSource {
    var columns: [String: [[Any]]] = [
        "all.persistentID": [[secondID, wavID, firstID]],
        "all.kind": [["AAC audio file", "WAV audio file", "MPEG audio file"]],
        "lyrics.persistentID": [[firstID, secondID]],
        "lyrics.lyrics": [["\u{FEFF}verse\r\ne\u{301} 🎵\n'quoted' \\ text", ""]]
    ]
    var reads: [String] = []
    var excluded: Set<String>?
    var failure: Int?
    var count = 3

    func fileTrackCount() throws -> Int { count }

    func strings(_ property: String, lyricsOnly: Bool) throws -> [Any] {
        let key = "\(lyricsOnly ? "lyrics" : "all").\(property)"
        reads.append(key)
        if key == "lyrics.lyrics", let failure { throw MusicAutomationErrors.failureMessage(failure) }
        guard let results = columns[key], let result = results.first else {
            throw MusicTextError(message: "unexpected fixture read: \(key)")
        }
        if results.count > 1 { columns[key]!.removeFirst() }
        return result
    }

    func excludeLyricsKinds(_ kinds: Set<String>) throws { excluded = kinds }
}

final class MusicAutomationAuthorizationTests: XCTestCase {
    @MainActor
    func testAlreadyGrantedAccessIsVisibleWithoutPrompting() async {
        var prompts: [Bool] = []
        let authorization = MusicAutomationAuthorization { prompt in
            prompts.append(prompt)
            return 0
        }
        await authorization.refresh()
        XCTAssertEqual(authorization.status, .authorized)
        XCTAssertEqual(authorization.status.message, "Music automation access granted.")
        XCTAssertFalse(authorization.status.canRequest)
        XCTAssertEqual(prompts, [false])
        await authorization.request()
        XCTAssertEqual(authorization.status, .authorized)
        XCTAssertFalse(authorization.isChecking)
    }

    @MainActor
    func testRequestUpdatesPreviouslyUnrequestedAccess() async {
        var prompts: [Bool] = []
        let authorization = MusicAutomationAuthorization { prompt in
            prompts.append(prompt)
            return prompt ? 0 : -1744
        }
        await authorization.refresh()
        XCTAssertEqual(authorization.status, .notDetermined)
        XCTAssertTrue(authorization.status.canRequest)
        await authorization.request()
        XCTAssertEqual(authorization.status.message, "Music automation access granted.")
        XCTAssertEqual(prompts, [false, true])
    }

    @MainActor
    func testDeniedAccessRefreshesAfterSettingsChangeWithoutPrompting() async {
        var code: Int32 = -1743
        var prompts: [Bool] = []
        let authorization = MusicAutomationAuthorization { prompt in
            prompts.append(prompt)
            return code
        }
        await authorization.request()
        XCTAssertEqual(authorization.status, .denied)
        XCTAssertTrue(authorization.status.message.contains("System Settings"))
        XCTAssertFalse(authorization.status.canRequest)
        code = 0
        await authorization.refresh()
        XCTAssertEqual(authorization.status, .authorized)
        code = -1743
        await authorization.refresh()
        XCTAssertEqual(authorization.status, .denied)
        XCTAssertEqual(prompts, [true, false, false])
    }

    @MainActor
    func testUnavailableMusicAndCheckErrorsDoNotClaimDeniedOrGranted() async {
        var code: Int32 = -600
        let authorization = MusicAutomationAuthorization { _ in code }
        await authorization.refresh()
        XCTAssertEqual(authorization.status, .musicNotRunning)
        XCTAssertEqual(authorization.status.message, "Open Music to check automation access.")
        code = -1712
        await authorization.refresh()
        XCTAssertEqual(authorization.status, .failed(-1712))
        XCTAssertTrue(authorization.status.message.contains("-1712"))
    }

    @MainActor
    func testPendingPermissionRequestRemainsResponsiveAndIgnoresDuplicateChecks() async {
        let started = AsyncStream<Void>.makeStream()
        var finish: CheckedContinuation<Int32, Never>?
        var prompts: [Bool] = []
        let authorization = MusicAutomationAuthorization { prompt in
            prompts.append(prompt)
            return await withCheckedContinuation { continuation in
                finish = continuation
                started.continuation.yield(())
            }
        }
        let request = Task { await authorization.request() }
        for await _ in started.stream { break }
        XCTAssertTrue(authorization.isChecking)
        await authorization.refresh()
        XCTAssertEqual(prompts, [true])
        finish?.resume(returning: 0)
        await request.value
        XCTAssertEqual(authorization.status, .authorized)
        XCTAssertFalse(authorization.isChecking)
        started.continuation.finish()
    }
}

final class ExportTextTests: XCTestCase {
    private var comments: [TrackComments] {
        [TrackComments(id: firstID, comments: "\u{FEFF}note\r\ne\u{301} 日本語"),
         TrackComments(id: secondID, comments: ""), TrackComments(id: wavID, comments: "wav note")]
    }

    func testNativeSnapshotAssociatesIDsAndPreservesRawText() throws {
        let source = FixtureMusic()
        let result = try MusicTextExport.read(comments: comments, source: source)
        XCTAssertEqual(source.excluded, ["WAV audio file"])
        XCTAssertEqual(Array(result[firstID]!.lyrics.utf8), Array("\u{FEFF}verse\r\ne\u{301} 🎵\n'quoted' \\ text".utf8))
        XCTAssertEqual(Array(result[firstID]!.comments.utf8), Array(comments[0].comments.utf8))
        XCTAssertEqual(result[secondID], TrackText(lyrics: "", comments: ""))
        XCTAssertEqual(result[wavID], TrackText(lyrics: "", comments: "wav note"))
        XCTAssertEqual(Set(result.keys), [firstID, secondID, wavID])
        XCTAssertFalse(source.reads.contains { $0.contains("comment") })
    }

    func testUnknownKindsFailBeforeLyricsReadEvenOutsideExportEligibility() {
        let source = FixtureMusic()
        source.columns["all.kind"] = [["AAC audio file", "future file type", "MPEG audio file"]]
        XCTAssertThrowsError(try MusicTextExport.read(comments: [comments[0]], source: source)) { error in
            XCTAssertTrue(error.localizedDescription.contains("future file type"))
        }
        XCTAssertNil(source.excluded)
        XCTAssertFalse(source.reads.contains("lyrics.lyrics"))
    }

    func testReturnsOnlyEligibleTracksAfterClassifyingAllFileTracks() throws {
        let result = try MusicTextExport.read(comments: [comments[0]], source: FixtureMusic())
        XCTAssertEqual(Set(result.keys), [firstID])
        XCTAssertEqual(result[firstID]!.comments, comments[0].comments)
    }

    func testInvalidCommentsFailBeforeAutomationReads() {
        for invalid in [[comments[0], comments[0]], [TrackComments(id: firstID, comments: "invalid\0text")]] {
            let source = FixtureMusic()
            XCTAssertThrowsError(try MusicTextExport.read(comments: invalid, source: source))
            XCTAssertTrue(source.reads.isEmpty)
        }
    }

    func testEveryAllowlistedKindIsReadAndOnlyBlockedKindsAssumeBlank() throws {
        for kind in LyricsKindPolicy.music.allowed {
            let source = FixtureMusic()
            source.columns["all.kind"] = [[kind, "WAV audio file", kind]]
            let result = try MusicTextExport.read(comments: comments, source: source)
            XCTAssertFalse(result[firstID]!.lyrics.isEmpty)
            XCTAssertEqual(result[wavID]!.lyrics, "")
        }
    }

    func testInvalidPoliciesFailBeforeAnyRead() {
        for policy in [LyricsKindPolicy(allowed: [], blocked: []),
                       LyricsKindPolicy(allowed: ["same"], blocked: ["same"])] {
            let source = FixtureMusic()
            XCTAssertThrowsError(try MusicTextExport.read(comments: comments, source: source, policy: policy))
            XCTAssertTrue(source.reads.isEmpty)
        }
    }

    func testEmptyAndEntirelyBlockedLibraries() throws {
        let source = FixtureMusic()
        source.count = 0
        source.columns = ["all.persistentID": [[]], "all.kind": [[]],
                          "lyrics.persistentID": [[]], "lyrics.lyrics": [[]]]
        XCTAssertTrue(try MusicTextExport.read(comments: [], source: source).isEmpty)
        source.count = 1
        source.columns["all.persistentID"] = [[wavID]]
        source.columns["all.kind"] = [["WAV audio file"]]
        XCTAssertEqual(try MusicTextExport.read(comments: [comments[2]], source: source)[wavID],
                       TrackText(lyrics: "", comments: "wav note"))
    }

    func testAutomationErrorsCannotBecomeSuccessfulEmptyArrays() {
        for code in [-1743, -1744, -1712, -600] {
            let errors = MusicAutomationErrors()
            var event = AppleEvent()
            XCTAssertThrowsError(try errors.checked {
                withUnsafePointer(to: &event) {
                    _ = errors.eventDidFail($0, withError: NSError(domain: NSOSStatusErrorDomain, code: code))
                }
                return [String]()
            }) { error in
                XCTAssertTrue(error.localizedDescription.contains(String(code)))
            }
        }
    }

    private func execute(_ query: PostgresQuery, on connection: PostgresConnection) async throws {
        let rows = try await connection.query(query, logger: .init(label: "export-tests"))
        for try await _ in rows {}
    }

    private func withDatabase(_ body: (PostgresConnection) async throws -> Void) async throws {
        let env = ProcessInfo.processInfo.environment
        let configPath = try XCTUnwrap(env["EXPORT_TEST_CONFIG_PATH"])
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let username = try XCTUnwrap(config["database_username"] as? String)
        let password = config["database_password"] as? String ?? ""
        let client = PostgresClient(configuration: .init(host: "localhost", username: username,
                                                        password: password, database: "warehouse_test", tls: .disable))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            defer { group.cancelAll() }
            try await client.withConnection { connection in
                try await body(connection)
            }
        }
    }

    private func createTracks(on connection: PostgresConnection) async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("export/CreateTables.sql")
        let queries = try String(contentsOf: url, encoding: .utf8).components(separatedBy: ";")
        let tracks = try XCTUnwrap(queries.first { $0.contains("CREATE TABLE tracks (") })
        let temporary = tracks.replacingOccurrences(of: "CREATE TABLE tracks", with: "CREATE TEMP TABLE tracks")
        try await execute(PostgresQuery(unsafeSQL: temporary), on: connection)
    }

    private func track(_ id: String, text: TrackText, filename: String = "fixture.mp3") -> InsertTrackQuery {
        InsertTrackQuery(id: id, name: "fixture", sortName: "", artistId: nil, albumArtistId: nil,
                         albumId: nil, genreId: nil, year: 2026, duration: 60, start: 0, finish: 60,
                         trackNumber: 1, discNumber: 1, playCount: 0, rating: 0,
                         musicFilename: filename, artworkFilename: nil, addedDate: nil,
                         lyrics: text.lyrics, comments: text.comments)
    }

    private func storedTracks(on connection: PostgresConnection) async throws -> [String: TrackText] {
        let rows = try await connection.query("SELECT id::text,lyrics,comments FROM tracks",
                                              logger: .init(label: "export-tests"))
        var result: [String: TrackText] = [:]
        for try await (id, lyrics, comments) in rows.decode((String, String, String).self) {
            result[id] = TrackText(lyrics: lyrics, comments: comments)
        }
        return result
    }

    func testDatabaseStoresExactTextAndRereadsAfterDirectEdits() async throws {
        try await withDatabase { connection in
            try await self.createTracks(on: connection)
            try await self.execute("CREATE TEMP TABLE export_finished (finished_at timestamptz)", on: connection)
            let source = FixtureMusic()
            var comments = self.comments
            for iteration in 0..<3 {
                let expected = try MusicTextExport.read(comments: comments, source: source)
                try await MusicTextExport.run(comments: comments, source: source) { snapshot in
                    try await self.execute("DROP TABLE tracks", on: connection)
                    try await self.createTracks(on: connection)
                    try await self.execute(insertTracksQuery(snapshot.sorted { $0.key < $1.key }.map {
                        self.track($0.key, text: $0.value)
                    }), on: connection)
                    try await self.execute(insertExportFinished(), on: connection)
                }
                let stored = try await self.storedTracks(on: connection)
                XCTAssertEqual(stored, expected, "every export must store fresh text")
                XCTAssertEqual(Array(stored[firstID]!.lyrics.utf8), Array(expected[firstID]!.lyrics.utf8))
                XCTAssertEqual(Array(stored[firstID]!.comments.utf8), Array(expected[firstID]!.comments.utf8))
                source.columns["lyrics.lyrics"] = [["direct music edit \(iteration)\n🎶", ""]]
                comments[0] = TrackComments(id: firstID, comments: "direct comment edit \(iteration)\n雪")
            }
        }
    }

    func testFailedReadsNeverReachDestructiveWorkOrMarkSuccess() async throws {
        let failures: [(String, (FixtureMusic) -> Void)] = [
            ("denied", { $0.failure = -1743 }), ("timeout", { $0.failure = -1712 }),
            ("other automation failure", { $0.failure = -600 }),
            ("missing allowed lyrics", { $0.columns["lyrics.lyrics"] = [["only one"]] }),
            ("null lyrics", { $0.columns["lyrics.lyrics"] = [[NSNull(), ""]] }),
            ("non-text lyrics", { $0.columns["lyrics.lyrics"] = [[42, ""]] }),
            ("nul lyrics", { $0.columns["lyrics.lyrics"] = [["\0", ""]] }),
            ("missing id", { $0.columns["all.persistentID"] = [[firstID, wavID]] }),
            ("short file-track inventory", { $0.count = 4 }),
            ("unmatched export id", {
                $0.columns["all.persistentID"] = [[firstID, wavID, "0000000000000004"]]
            }),
            ("duplicate id", { $0.columns["all.persistentID"] = [[firstID, firstID, wavID]] }),
            ("invalid id", { $0.columns["all.persistentID"] = [[firstID, "bad", wavID]] }),
            ("unknown kind", { $0.columns["all.kind"] = [["new type", "WAV audio file", "MPEG audio file"]] }),
            ("null kind", { $0.columns["all.kind"] = [[NSNull(), "WAV audio file", "MPEG audio file"]] }),
            ("short kind inventory", { $0.columns["all.kind"] = [["MPEG audio file"]] }),
            ("wrong lyric ids", { $0.columns["lyrics.persistentID"] = [[firstID, wavID]] }),
            ("reordered lyric ids", { $0.columns["lyrics.persistentID"] = [[firstID, secondID], [secondID, firstID]] }),
            ("changed inventory", { $0.columns["all.persistentID"] = [[secondID, wavID, firstID], [firstID, wavID, secondID]] }),
            ("changed kinds", { $0.columns["all.kind"] = [["AAC audio file", "WAV audio file", "MPEG audio file"],
                                                       ["AAC audio file", "MPEG audio file", "WAV audio file"]] })
        ]
        try await withDatabase { connection in
            try await self.createTracks(on: connection)
            try await self.execute("CREATE TEMP TABLE export_finished (finished_at timestamptz)", on: connection)
            try await self.execute(insertTracksQuery([self.track(firstID, text: TrackText(lyrics: "old", comments: "old"))]),
                                   on: connection)
            let baseline = try await self.storedTracks(on: connection)
            for (name, configure) in failures {
                let source = FixtureMusic()
                configure(source)
                var destructiveWorkReached = false
                var succeeded = false
                do {
                    try await MusicTextExport.run(comments: self.comments, source: source) { _ in
                        destructiveWorkReached = true
                        try await self.execute("DROP TABLE tracks", on: connection)
                        try await self.execute(insertExportFinished(), on: connection)
                    }
                    succeeded = true
                } catch {}
                XCTAssertFalse(succeeded, name)
                XCTAssertFalse(destructiveWorkReached, name)
                let stored = try await self.storedTracks(on: connection)
                XCTAssertEqual(stored, baseline, name)
                let rows = try await connection.query("SELECT count(*) FROM export_finished", logger: .init(label: "export-tests"))
                for try await count in rows.decode(Int.self) { XCTAssertEqual(count, 0, name) }
            }
        }
    }
}
