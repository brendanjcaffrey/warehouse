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

    CREATE_TRACKS_SQL = <<-SQL
      create table tracks (
        id INTEGER PRIMARY KEY,
        name TEXT,
        sort_name TEXT,
        artist TEXT,
        sort_artist TEXT,
        album TEXT,
        sort_album TEXT,
        genre_id INTEGER,
        duration REAL,
        start REAL,
        finish REAL,
        track INTEGER,
        disc INTEGER,
        file TEXT
      );
    SQL

    TRACK_SQL = <<-SQL
      INSERT INTO tracks (id, name, sort_name, artist, sort_artist, album, sort_album, genre_id,
        duration, start, finish, track, disc, file)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
    SQL

    def initialize(file_name)
      File.unlink(file_name) if File.exists?(file_name)
      @genres = {}

      @db = SQLite3::Database.new(file_name)
      @db.execute(CREATE_GENRES_SQL)
      @db.execute(CREATE_TRACKS_SQL)
    end

    def create_track(track)
      @db.execute(TRACK_SQL, [track.id, track.name, track.sort_name, track.artist,
        track.sort_artist, track.album, track.sort_album, genre_id(track.genre), track.duration,
        track.start, track.finish, track.track, track.disc, track.file])
    end

    private

    def genre_id(name)
      @genres[name] || create_genre(name)
    end

    def create_genre(name)
      @db.execute(GENRE_SQL, name)
      @genres[name] = @db.last_insert_row_id
    end
  end
end
