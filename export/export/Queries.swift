import Foundation
import PostgresNIO

let GET_TABLES_SQL = "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public';"
let DROP_TABLE_SQL = "DROP TABLE IF EXISTS \"%@\" CASCADE;"
let GET_TRACK_MD5S_SQL = "SELECT id,file_md5,artwork_filename FROM tracks;"

func loadQueriesFromFile(_ name: String) throws -> [String] {
    guard let url = Bundle.main.url(forResource: name, withExtension: "sql") else {
        throw NSError(domain: "SQLLoader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not find SQL file in bundle."])
    }
    return try String(contentsOf: url)
            .components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
}

let NUM_GENRE_VALUES = 2
struct InsertGenreQuery {
    var id: Int
    var name: String
}
func insertGenresQuery(genres: [InsertGenreQuery]) -> PostgresQuery {
    var binds = PostgresBindings(capacity: genres.count * NUM_GENRE_VALUES)
    var values: [String] = []
    for (i, genre) in genres.enumerated() {
        values.append("($\(i*NUM_GENRE_VALUES+1),$\(i*NUM_GENRE_VALUES+2))")
        binds.append(genre.id)
        binds.append(genre.name)
    }
    let query = "INSERT INTO genres (id, name) VALUES \(values.joined(separator: ","));"
    return PostgresQuery(unsafeSQL: query, binds: binds)
}

let NUM_SORT_NAME_VALUES = 3
struct InsertSortNameQuery {
    var id: Int
    var name: String
    var sortName: String
}
func insertSortNamesQuery(table: String, sortNames: [InsertSortNameQuery]) -> PostgresQuery {
    var binds = PostgresBindings(capacity: sortNames.count * NUM_SORT_NAME_VALUES)
    var values: [String] = []
    for (i, artist) in sortNames.enumerated() {
        values.append("($\(i*NUM_SORT_NAME_VALUES+1),$\(i*NUM_SORT_NAME_VALUES+2),$\(i*NUM_SORT_NAME_VALUES+3))")
        binds.append(artist.id)
        binds.append(artist.name)
        binds.append(artist.sortName)
    }
    let query = "INSERT INTO \(table) (id, name, sort_name) VALUES \(values.joined(separator: ","));"
    return PostgresQuery(unsafeSQL: query, binds: binds)
}
typealias InsertArtistQuery = InsertSortNameQuery
func insertArtistsQuery(_ artists: [InsertArtistQuery]) -> PostgresQuery {
    return insertSortNamesQuery(table: "artists", sortNames: artists)
}
typealias InsertAlbumQuery = InsertSortNameQuery
func insertAlbumsQuery(_ albums: [InsertAlbumQuery]) -> PostgresQuery {
    return insertSortNamesQuery(table: "albums", sortNames: albums)
}

let NUM_TRACK_VALUES = 18
struct InsertTrackQuery {
    var id: String
    var name: String
    var sortName: String
    var artistId: Optional<Int>
    var albumArtistId: Optional<Int>
    var albumId: Optional<Int>
    var genreId: Optional<Int>
    var year: Int
    var duration: Double
    var start: Double
    var finish: Double
    var trackNumber: Int
    var discNumber: Int
    var playCount: Int
    var rating: Int
    var ext: String
    var fileMd5: String
    var artworkFilename: Optional<String>
}
func insertTracksQuery(_ tracks: [InsertTrackQuery]) -> PostgresQuery {
    var binds = PostgresBindings(capacity: tracks.count * NUM_TRACK_VALUES)
    var values: [String] = []
    for (i, track) in tracks.enumerated() {
        let valuesInner = (1...NUM_TRACK_VALUES).map { "$\(i*NUM_TRACK_VALUES+$0)" }.joined(separator: ",")
        values.append("(\(valuesInner))")
        binds.append(track.id)
        binds.append(track.name)
        binds.append(track.sortName)
        binds.append(track.artistId)
        binds.append(track.albumArtistId)
        binds.append(track.albumId)
        binds.append(track.genreId)
        binds.append(track.year)
        binds.append(track.duration)
        binds.append(track.start)
        binds.append(track.finish)
        binds.append(track.trackNumber)
        binds.append(track.discNumber)
        binds.append(track.playCount)
        binds.append(track.rating)
        binds.append(track.ext)
        binds.append(track.fileMd5)
        binds.append(track.artworkFilename)
    }

    let query = "INSERT INTO tracks (id,name,sort_name,artist_id,album_artist_id,album_id,genre_id,year,duration,start,finish,track_number,disc_number,play_count,rating,ext,file_md5,artwork_filename) VALUES \(values.joined(separator: ","));"
    return PostgresQuery(unsafeSQL: query, binds: binds)
}

let NUM_PLAYLIST_VALUES = 4
struct InsertPlaylistQuery {
    var id: String
    var name: String
    var isLibrary: Bool
    var parentId: Optional<String>
}
func insertPlaylistsQuery(_ playlists: [InsertPlaylistQuery]) -> PostgresQuery {
    var binds = PostgresBindings(capacity: playlists.count * NUM_PLAYLIST_VALUES)
    var values: [String] = []
    for (i, playlist) in playlists.enumerated() {
        values.append("($\(i*NUM_PLAYLIST_VALUES+1),$\(i*NUM_PLAYLIST_VALUES+2),$\(i*NUM_PLAYLIST_VALUES+3),$\(i*NUM_PLAYLIST_VALUES+4))")
        binds.append(playlist.id)
        binds.append(playlist.name)
        binds.append(playlist.isLibrary ? 1 : 0)
        binds.append(playlist.parentId)
    }
    let query = "INSERT INTO playlists (id, name, is_library, parent_id) VALUES \(values.joined(separator: ","));"
    return PostgresQuery(unsafeSQL: query, binds: binds)
}

func insertPlaylistTracksQuery(playlistId: String, trackIds: [String]) -> PostgresQuery {
    if trackIds.isEmpty { fatalError() }
    var binds = PostgresBindings(capacity: trackIds.count + 1)
    binds.append(playlistId)
    var values: [String] = []
    for (i, trackId) in trackIds.enumerated() {
        values.append("($1,$\(i+2))")
        binds.append(trackId)
    }
    let query = "INSERT INTO playlist_tracks (playlist_id, track_id) VALUES \(values.joined(separator: ","));"
    return PostgresQuery(unsafeSQL: query, binds: binds)
}

func insertLibraryMetadata(totalFileSize: Int64) -> PostgresQuery {
    var binds = PostgresBindings(capacity: 1)
    binds.append(totalFileSize)
    return PostgresQuery(unsafeSQL: "INSERT INTO library_metadata (total_file_size) VALUES ($1)", binds: binds)
}

func insertExportFinished() -> PostgresQuery {
    return PostgresQuery(stringLiteral: "INSERT INTO export_finished (finished_at) VALUES (current_timestamp)")
}

