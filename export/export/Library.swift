import iTunesLibrary
import MusicKit
import PostgresNIO
import CryptoKit

struct ExportError: LocalizedError {
    let message: String

    var errorDescription: String? {
        return message
    }
}

struct ExportProgress {
    var totalTracks: Int = 0
    var processedTracks: Int = 0

    var tableQueryTime: Double = 0.0
    var genreQueryTime: Double = 0.0
    var artistQueryTime: Double = 0.0
    var albumQueryTime: Double = 0.0
    var trackQueryTime: Double = 0.0
    var playlistQueryTime: Double = 0.0
    var playlistTrackQueryTime: Double = 0.0
    var artworkTime: Double = 0.0
    var trackMd5Time: Double = 0.0
    var totalTime: Double = 0.0

    func toString() -> String {
        var msg = String(format: "export finished in %.3f seconds\n", totalTime)
        msg.append(contentsOf: "latency breakdown:\n")
        appendTime(&msg, "creating tables", tableQueryTime, totalTime)
        appendTime(&msg, "inserting genres", genreQueryTime, totalTime)
        appendTime(&msg, "inserting artists", artistQueryTime, totalTime)
        appendTime(&msg, "inserting albums", albumQueryTime, totalTime)
        appendTime(&msg, "inserting tracks", trackQueryTime, totalTime)
        appendTime(&msg, "inserting playlists", playlistQueryTime, totalTime)
        appendTime(&msg, "inserting playlist tracks", playlistTrackQueryTime, totalTime)
        appendTime(&msg, "artwork file md5", artworkTime, totalTime)
        appendTime(&msg, "track file md5", trackMd5Time, totalTime)
        return msg
    }

    private func appendTime(_ msg: inout String, _ desc: String, _ time: Double, _ total: Double) {
        msg += String(format: "%@: %.3fs (%.2f%%)\n", desc, time, time / total * 100)
    }
}

class ExportProgressModel: ObservableObject {
    @Published var status = ExportProgress()
}

struct ExistingMD5s {
    var music: String
    var artwork: String?
}

class Library {
    var dbConfig: PostgresClient.Configuration

    var genreIds: Dictionary<String, Int> = [:]
    var artistIds: Dictionary<String, Int> = [:]
    var albumIds: Dictionary<String, Int> = [:]

    var trackIds: Set<String> = []

    var totalTrackFileSize: Int64 = 0
    var totalArtworkFileSize: Int64 = 0

    var existingArtwork: Set<String> = []
    var seenArtworks: Set<String> = []

    var existingMD5s: Dictionary<String, ExistingMD5s> = [:]

    init(pgConfig: PostgresClient.Configuration) {
        self.dbConfig = pgConfig
    }

    func export(musicPath: String, artworkDirURL: URL, progress: ExportProgressModel, fast: Bool) async throws -> Optional<String> {
        self.totalTrackFileSize = 0
        self.totalArtworkFileSize = 0
        self.seenArtworks = []
        self.existingArtwork = []

        await MainActor.run {
            progress.status.totalTracks = 0
            progress.status.processedTracks = 0

            progress.status.tableQueryTime = 0.0
            progress.status.genreQueryTime = 0.0
            progress.status.artistQueryTime = 0.0
            progress.status.albumQueryTime = 0.0
            progress.status.trackQueryTime = 0.0
            progress.status.playlistQueryTime = 0.0
            progress.status.playlistTrackQueryTime = 0.0
            progress.status.totalTime = 0.0
            progress.status.artworkTime = 0.0
            progress.status.trackMd5Time = 0.0
        }

        let start = Date()
        let client = PostgresClient(configuration: dbConfig)
        return await withTaskGroup(of: Void.self) { taskGroup in
            defer { taskGroup.cancelAll() }
            taskGroup.addTask { await client.run() }
            do {
                let lib = try! ITLibrary(apiVersion: "1.1")
                if !fast { try self.gatherExistingArtwork(artworkDirURL) }
                if fast { try await self.gatherExistingMD5s(client) }
                try await self.dropTables(client, progress)
                try await self.createTables(client, progress)
                try await self.exportGenres(lib, client, progress)
                try await self.exportArtists(lib, client, progress)
                try await self.exportAlbums(lib, client, progress)
                try await self.exportTracks(lib, client, musicPath, artworkDirURL, progress, fast)
                try await self.exportPlaylists(lib, client, progress)
                try await self.finishExport(client)
                if !fast { try self.cleanupArtwork(artworkDirURL) }
                await MainActor.run { progress.status.totalTime = Date().timeIntervalSince(start) }
                return nil
            } catch let error {
                return "error: \(String(reflecting: error))"
            }
        }
    }

    private func gatherExistingArtwork(_ artworkDirURL: URL) throws {
        self.existingArtwork = Set(try FileManager.default.contentsOfDirectory(
            at: artworkDirURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).map { $0.lastPathComponent })
    }

    private func gatherExistingMD5s(_ client: PostgresClient) async throws {
        let result = try await client.query(PostgresQuery(stringLiteral: GET_TRACK_MD5S_SQL))
        for try await (id, music, artwork) in result.decode((String, String, String?).self) {
            existingMD5s[id] = ExistingMD5s(music: music, artwork: artwork)
        }
    }

    private func dropTables(_ client: PostgresClient, _ progress: ExportProgressModel) async throws {
        let now = Date()
        let result = try await client.query(PostgresQuery(stringLiteral: GET_TABLES_SQL))
        for try await (tableName) in result.decode((String).self) {
            let escapedTableName = tableName.replacingOccurrences(of: "\"", with: "\"\"")
            let query = String(format: DROP_TABLE_SQL, escapedTableName)
            try await client.query(PostgresQuery(stringLiteral: query))
        }
        await MainActor.run { progress.status.tableQueryTime = Date().timeIntervalSince(now) }
    }

    private func createTables(_ client: PostgresClient, _ progress: ExportProgressModel) async throws {
        let now = Date()
        guard let url = Bundle.main.url(forResource: "CreateTables", withExtension: "sql") else {
            throw NSError(domain: "SQLLoader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not find SQL file in bundle."])
        }
        let queries = try String(contentsOf: url)
                .components(separatedBy: ";")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        for query in queries {
            try await client.query(PostgresQuery(stringLiteral: query))
        }
        await MainActor.run { progress.status.tableQueryTime = Date().timeIntervalSince(now) }
    }

    private func shouldIgnoreItem(_ item: ITLibMediaItem) -> Bool {
        return item.mediaKind != .kindSong || item.locationType != .file
    }

    private func exportGenres(_ lib: ITLibrary, _ client: PostgresClient, _ progress: ExportProgressModel) async throws {
        var genres: [InsertGenreQuery] = []
        for item in lib.allMediaItems {
            if shouldIgnoreItem(item) { continue }
            let genreName = cleanName(item.genre)
            if genreIds[genreName] == nil {
                let genreId = genreIds.count + 1
                genreIds[genreName] = genreId
                genres.append(InsertGenreQuery(id: genreId, name: genreName))
            }
        }

        let start = Date()
        try await client.query(insertGenresQuery(genres: genres))
        let duration = Date().timeIntervalSince(start)
        await MainActor.run { progress.status.genreQueryTime = duration }
    }

    private func exportArtists(_ lib: ITLibrary, _ client: PostgresClient, _ progress: ExportProgressModel) async throws {
        var artists: [InsertArtistQuery] = []
        for item in lib.allMediaItems {
            if shouldIgnoreItem(item) { continue }

            if let rawName = item.artist?.name {
                let name = cleanName(rawName)
                if artistIds[name] == nil {
                    let artistId = artistIds.count + 1
                    var sortName = item.artist?.sortName == nil ? name : cleanName(item.artist!.sortName!)
                    if sortName == name { sortName = "" }
                    artistIds[name] = artistId
                    artists.append(InsertArtistQuery(id: artistId, name: name, sortName: sortName))
                }
            }

            if let rawName = item.album.albumArtist {
                let name = cleanName(rawName)
                if artistIds[name] == nil {
                    let artistId = artistIds.count + 1
                    var sortName = item.album.sortAlbumArtist == nil ? name : cleanName(item.album.sortAlbumArtist!)
                    if sortName == name { sortName = "" }
                    artistIds[name] = artistId
                    artists.append(InsertArtistQuery(id: artistId, name: name, sortName: sortName))
                }
            }
        }

        let start = Date()
        try await client.query(insertArtistsQuery(artists))
        let duration = Date().timeIntervalSince(start)
        await MainActor.run { progress.status.artistQueryTime = duration }
    }

    private func exportAlbums(_ lib: ITLibrary, _ client: PostgresClient, _ progress: ExportProgressModel) async throws {
        var albums: [InsertAlbumQuery] = []
        for item in lib.allMediaItems {
            if shouldIgnoreItem(item) { continue }

            if let rawName = item.album.title {
                let name = cleanName(rawName)
                if albumIds[name] == nil {
                    let albumId = albumIds.count + 1
                    var sortName = item.album.sortTitle == nil ? name : cleanName(item.album.sortTitle!)
                    if sortName == name { sortName = "" }
                    albumIds[name] = albumId
                    albums.append(InsertAlbumQuery(id: albumId, name: name, sortName: sortName))
                }
            }
        }

        let start = Date()
        try await client.query(insertAlbumsQuery(albums))
        let duration = Date().timeIntervalSince(start)
        await MainActor.run { progress.status.albumQueryTime = duration }
    }

    private func exportTracks(_ lib: ITLibrary, _ client: PostgresClient, _ musicPath: String, _ artworkDirURL: URL, _ progress: ExportProgressModel, _ fast: Bool) async throws {
        let allItems = lib.allMediaItems
        await MainActor.run { progress.status.totalTracks = allItems.count }

        var lastUpdate = Date()
        var trackMd5Duration = 0.0
        var artworkDuration = 0.0
        var trackQueryDuration = 0.0
        var tracks: [InsertTrackQuery] = []
        for (i, item) in allItems.enumerated() {
            if shouldIgnoreItem(item) { continue }

            let location = item.location
            if location == nil { fatalError() }

            let persistentId = formatPersistentId(item.persistentID)
            let genreId = genreIds[cleanName(item.genre)]
            let artistId = item.artist?.name != nil ? artistIds[cleanName(item.artist!.name!)] : nil
            let albumArtistId = item.album.albumArtist != nil ? artistIds[cleanName(item.album.albumArtist!)] : nil
            let albumId = item.album.title != nil ? albumIds[cleanName(item.album.title!)] : nil

            let title = cleanName(item.title)
            var sortTitle = item.sortTitle == nil ? title : cleanName(item.sortTitle!)
            if sortTitle == title { sortTitle = "" }

            let totalTime = Double(item.totalTime) / 1000.0
            let startTime = Double(item.startTime) / 1000.0
            let finishTime = item.stopTime == 0 ? totalTime : Double(item.stopTime) / 1000.0
            let rating = item.rating == 1 || item.isRatingComputed ? 0 : item.rating

            let filePath = Config.checkMusicPath(musicPath: musicPath, trackLocation: location!)
            if !filePath.success {
                throw ExportError(message: "track with id \(item.persistentID) has invalid file path: \(filePath.errorMsg!)")
            }
            let fileExt = location!.pathExtension
            var fileMD5: String?
            var artworkFilename: String?
            if fast, let existingMD5 = self.existingMD5s[persistentId] {
                fileMD5 = existingMD5.music
                artworkFilename = existingMD5.artwork
                if let af = artworkFilename, !af.isEmpty {
                    seenArtworks.insert(af)
                    let fullPath = artworkDirURL.appendingPathComponent(af)
                    totalArtworkFileSize += try getFileSize(fullPath)
                }
            }
            if fileMD5 == nil {
                let start = Date()
                fileMD5 = try getFileMD5(file: location!)
                trackMd5Duration += Date().timeIntervalSince(start)
            }
            totalTrackFileSize += try getFileSize(location!)

            if artworkFilename == nil {
                artworkFilename = try await getArtworkFilename(item, artworkDirURL, &artworkDuration)
            }
            tracks.append(InsertTrackQuery(
                id: persistentId, name: title, sortName: sortTitle, artistId: artistId, albumArtistId: albumArtistId,
                albumId: albumId, genreId: genreId, year: item.year, duration: totalTime, start: startTime, finish: finishTime,
                trackNumber: item.trackNumber, discNumber: item.album.discNumber, playCount: item.playCount, rating: rating,
                ext: fileExt, file: filePath.subpath!, fileMd5: fileMD5!, artworkFilename: artworkFilename
            ))
            trackIds.insert(persistentId)

            if tracks.count >= 1000 {
                let start = Date()
                try await client.query(insertTracksQuery(tracks))
                trackQueryDuration += Date().timeIntervalSince(start)
                tracks.removeAll()
            }

            let durationSinceLastUpdate = Date().timeIntervalSince(lastUpdate)
            if durationSinceLastUpdate > 0.25 {
                lastUpdate = Date()
                await MainActor.run { progress.status.processedTracks = i }
            }
        }

        if !tracks.isEmpty {
            let start = Date()
            try await client.query(insertTracksQuery(tracks))
            trackQueryDuration += Date().timeIntervalSince(start)
        }

        let artworkTime = artworkDuration
        let trackQueryTime = trackQueryDuration
        let trackMd5Time = trackMd5Duration
        await MainActor.run {
            progress.status.processedTracks = progress.status.totalTracks
            progress.status.trackQueryTime = trackQueryTime
            progress.status.artworkTime = artworkTime
            progress.status.trackMd5Time = trackMd5Time
        }
    }

    private func exportPlaylists(_ lib: ITLibrary, _ client: PostgresClient, _ progress: ExportProgressModel) async throws {
        let allPlaylists = lib.allPlaylists

        let playlists: [InsertPlaylistQuery] = allPlaylists.map { playlist in
            let id = formatPersistentId(playlist.persistentID)
            let parentId = playlist.parentID != nil ? formatPersistentId(playlist.parentID!) : nil
            return InsertPlaylistQuery(id: id, name: playlist.name, isLibrary: playlist.isPrimary, parentId: parentId)
        }
        let start = Date()
        try await client.query(insertPlaylistsQuery(playlists))
        let playlistDuration = Date().timeIntervalSince(start)

        var playlistTrackDuration = 0.0
        for playlist in allPlaylists {
            let id = formatPersistentId(playlist.persistentID)
            if !playlist.isPrimary { // no need to insert every track into the database for this one
                let playlistTrackIds = playlist.items.map { formatPersistentId($0.persistentID) }.filter { trackIds.contains($0) }
                if playlistTrackIds.isEmpty { continue }
                let start = Date()
                try await client.query(insertPlaylistTracksQuery(playlistId: id, trackIds: playlistTrackIds))
                playlistTrackDuration += Date().timeIntervalSince(start)
            }
        }

        let playlistTrackTime = playlistTrackDuration
        await MainActor.run {
            progress.status.playlistQueryTime = playlistDuration
            progress.status.playlistTrackQueryTime = playlistTrackTime
        }
    }

    private func finishExport(_ client: PostgresClient) async throws {
        try await client.query(insertLibraryMetadata(totalFileSize: totalTrackFileSize + totalArtworkFileSize))
        try await client.query(insertExportFinished())
    }

    private func cleanupArtwork(_ artworkDirURL: URL) throws {
        existingArtwork.subtracting(seenArtworks).forEach {
            try? FileManager.default.removeItem(at: artworkDirURL.appendingPathComponent($0))
        }
    }

    private func getArtworkFilename(_ item: ITLibMediaItem, _ directory: URL, _ duration: inout Double) async throws -> Optional<String> {
        var artworkFilename: Optional<String> = nil
        if let artwork = item.artwork {
            let start = Date()
            let imageData = artwork.imageData!
            var md5 = CryptoKit.Insecure.MD5()
            md5.update(data: imageData)
            let artworkMd5 = self.formatMD5Digest(md5.finalize())

            var artworkExt = ""
            switch artwork.imageDataFormat {
            case .PNG: artworkExt = "png"
            case .JPEG: artworkExt = "jpg"
            default: fatalError()
            }

            artworkFilename = "\(artworkMd5).\(artworkExt)"
            let fullPath = directory.appendingPathComponent(artworkFilename!)
            if !FileManager().fileExists(atPath: fullPath.path) {
                try imageData.write(to: fullPath)
            }
            if !seenArtworks.contains(artworkFilename!) {
                seenArtworks.insert(artworkFilename!)
                totalArtworkFileSize += try getFileSize(fullPath)
            }
            duration += Date().timeIntervalSince(start)
        }
        return artworkFilename
    }

    private func getFileMD5(file: URL, bufferSize: Int = 1024 * 1024 * 40) throws -> String {
        let file = try FileHandle(forReadingFrom: file)
        defer {
            file.closeFile()
        }

        var md5 = CryptoKit.Insecure.MD5()

        while autoreleasepool(invoking: {
            let data = file.readData(ofLength: bufferSize)
            if !data.isEmpty {
                md5.update(data: data)
                return true
            } else {
                return false
            }
        }) {
        }

        return formatMD5Digest(md5.finalize())
    }

    private func formatPersistentId(_ id: NSNumber) -> String {
        return String(format: "%016llx", id.int64Value).uppercased()
    }

    private func cleanName(_ str: String) -> String {
        // remove the utf BOM
        return str.replacingOccurrences(of: "\u{FEFF}", with: "")
    }

    private func formatMD5Digest(_ digest: CryptoKit.Insecure.MD5Digest) -> String {
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func getFileSize(_ url: URL) throws -> Int64 {
        return try url.resourceValues(forKeys: [.fileSizeKey]).allValues[.fileSizeKey] as! Int64
    }
}
