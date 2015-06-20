require 'sqlite3'

module Export
  class Database
    attr_reader :plays

    CREATE_GENRES_SQL = <<-SQL
      CREATE TABLE genres (
        id INTEGER PRIMARY KEY,
        name TEXT
      );
    SQL

    CREATE_ARTISTS_SQL = <<-SQL
      CREATE TABLE artists (
        id INTEGER PRIMARY KEY,
        name TEXT,
        sort_name TEXT
      );
    SQL

    CREATE_ALBUMS_SQL = <<-SQL
      CREATE TABLE albums (
        id INTEGER PRIMARY KEY,
        artist_id INTEGER,
        name TEXT,
        sort_name TEXT
      );
    SQL

    CREATE_TRACKS_SQL = <<-SQL
      CREATE TABLE tracks (
        id INTEGER PRIMARY KEY,
        name TEXT,
        sort_name TEXT,
        artist_id INTEGER,
        album_id INTEGER,
        genre_id INTEGER,
        duration REAL,
        start REAL,
        finish REAL,
        track INTEGER,
        track_count INTEGER,
        disc INTEGER,
        disc_count INTEGER,
        play_count INTEGER,
        ext TEXT,
        file TEXT
      );
    SQL

    CREATE_PLAYLISTS_SQL = <<-SQL
      CREATE TABLE playlists (
        id INTEGER PRIMARY KEY,
        name TEXT,
        parent_id INTEGER,
        count INTEGER
      );
    SQL

    CREATE_PLAYLIST_TRACK_SQL = <<-SQL
      CREATE TABLE playlist_tracks (
        playlist_id INTEGER,
        track_id INTEGER
      );
    SQL

    CREATE_PLAYS_SQL = <<-SQL
      CREATE TABLE plays (
        track_id INTEGER
      );
    SQL

    CREATE_USERS_SQL = <<-SQL
      CREATE TABLE users (
        token TEXT,
        username TEXT
      );
    SQL

    GENRE_SQL = 'INSERT INTO genres (name) VALUES (?);'

    ARTIST_SQL = 'INSERT INTO artists (name, sort_name) VALUES (?,?);'

    ALBUM_SQL = 'INSERT INTO albums (name, sort_name, artist_id) VALUES (?,?,?);'

    TRACK_SQL = <<-SQL
      INSERT INTO tracks (id, name, sort_name, artist_id, album_id, genre_id, duration,
      start, finish, track, track_count, disc, disc_count, play_count, ext, file)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
    SQL

    PLAYLIST_SQL = 'INSERT INTO playlists (id, name, parent_id, count) VALUES (?,?,?,?);'

    PLAYLIST_TRACK_SQL = 'INSERT INTO playlist_tracks (playlist_id, track_id) VALUES (?,?);'

    ACCEPTABLE_EXTENSIONS = ['mp3', 'mp4', 'm4a', 'aiff', 'aif', 'wav']

    def initialize(file_name)
      @file_name = file_name
      if File.exists?(@file_name)
        @plays = SQLite3::Database.new(@file_name).execute('SELECT * FROM plays');
      else
        @plays = []
      end

      @genres = {}
      @artists = {}
      @albums = {}
      @skipped_tracks = {}
    end

    def build_tables
      File.unlink(@file_name) if File.exists?(@file_name)
      @db = SQLite3::Database.new(@file_name)
      @db.execute(CREATE_GENRES_SQL)
      @db.execute(CREATE_ARTISTS_SQL)
      @db.execute(CREATE_ALBUMS_SQL)
      @db.execute(CREATE_TRACKS_SQL)
      @db.execute(CREATE_PLAYLISTS_SQL)
      @db.execute(CREATE_PLAYLIST_TRACK_SQL)
      @db.execute(CREATE_PLAYS_SQL)
      @db.execute(CREATE_USERS_SQL)
    end

    def create_track(track)
      ext = track.file.split('.').last.downcase
      if ACCEPTABLE_EXTENSIONS.index(ext) == nil
        puts "Skipping #{track.file} due to invalid extension #{ext.inspect}"
        @skipped_tracks[track.id] = true
        return
      end

      genre = genre_id(track.genre)
      artist = artist_id(track.artist, track.sort_artist)
      album = album_id(track.album, track.sort_album, artist)

      @db.execute(TRACK_SQL, [track.id, track.name, track.sort_name, artist, album, genre,
        track.duration, track.start, track.finish, track.track, track.track_count, track.disc,
        track.disc_count, track.play_count, ext, track.file])
    end

    def create_playlist(playlist)
      tracks = playlist.tracks.select { |track_id| !@skipped_tracks.has_key?(track_id.to_s) }
      @db.execute(PLAYLIST_SQL, playlist.id, playlist.name, playlist.parent_id, tracks.count)
      tracks.each { |track_id| @db.execute(PLAYLIST_TRACK_SQL, playlist.id, track_id) }
    end

    private

    def genre_id(name)
      @genres[name] || create_genre(name)
    end

    def create_genre(name)
      @db.execute(GENRE_SQL, name)
      @genres[name] = @db.last_insert_row_id
    end

    def artist_id(name, sort_name)
      @artists[name] || create_artist(name, sort_name)
    end

    def create_artist(name, sort_name)
      @db.execute(ARTIST_SQL, name, sort_name)
      @artists[name] = @db.last_insert_row_id
    end

    def album_id(name, sort_name, artist_id)
      @albums[artist_id] ||= {}
      @albums[artist_id][name] || create_album(name, sort_name, artist_id)
    end

    def create_album(name, sort_name, artist_id)
      @db.execute(ALBUM_SQL, name, sort_name, artist_id)
      @albums[artist_id][name] = @db.last_insert_row_id
    end
  end
end
