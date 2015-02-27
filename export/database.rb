require 'sqlite3'

module Export
  class Database
    CREATE_GENRES_SQL = <<-SQL
      create table genres (
        id INTEGER PRIMARY KEY,
        name TEXT
      )
    SQL

    GENRE_SQL = 'INSERT INTO genres (name) VALUES (?)'

    CREATE_ARTISTS_SQL = <<-SQL
      create table artists (
        id INTEGER PRIMARY KEY,
        name TEXT,
        sort_name TEXT
      )
    SQL

    ARTIST_SQL = 'INSERT INTO artists (name, sort_name) VALUES (?,?)'

    CREATE_ALBUMS_SQL = <<-SQL
      create table albums (
        id INTEGER PRIMARY KEY,
        artist_id INTEGER,
        name TEXT,
        sort_name TEXT
      )
    SQL

    ALBUM_SQL = 'INSERT INTO albums (name, sort_name, artist_id) VALUES (?,?,?)'

    CREATE_TRACKS_SQL = <<-SQL
      create table tracks (
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
        file TEXT
      );
    SQL

    TRACK_SQL = <<-SQL
      INSERT INTO tracks (id, name, sort_name, artist_id, album_id, genre_id,
        duration, start, finish, track, track_count, disc, disc_count, play_count, file)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
    SQL

    def initialize(file_name)
      File.unlink(file_name) if File.exists?(file_name)
      @genres = @albums = @artists = {}

      @db = SQLite3::Database.new(file_name)
      @db.execute(CREATE_GENRES_SQL)
      @db.execute(CREATE_ARTISTS_SQL)
      @db.execute(CREATE_ALBUMS_SQL)
      @db.execute(CREATE_TRACKS_SQL)
    end

    def create_track(track)
      genre = genre_id(track.genre)
      artist = artist_id(track.artist, track.sort_artist)
      album = album_id(track.album, track.sort_album, artist)

      @db.execute(TRACK_SQL, [track.id, track.name, track.sort_name, artist, album, genre,
        track.duration, track.start, track.finish, track.track, track.track_count, track.disc,
        track.disc_count, track.play_count, track.file])
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
