# frozen_string_literal: true

require 'pg'

module Export
  class Database
    attr_reader :plays

    DATABASE_EXISTS_SQL = 'SELECT datname FROM pg_database;'
    CREATE_DATABASE_SQL = 'CREATE DATABASE %s;'
    DROP_DATABASE_SQL = 'DROP DATABASE %s;'

    GET_PLAYS_SQL = 'SELECT track_id FROM plays;'
    GET_RATING_UPDATES_SQL = 'SELECT track_id, rating FROM rating_updates;'
    GET_NAME_UPDATES_SQL = 'SELECT track_id, name FROM name_updates;'
    GET_ARTIST_UPDATES_SQL = 'SELECT track_id, artist FROM artist_updates;'
    GET_ALBUM_UPDATES_SQL = 'SELECT track_id, album FROM album_updates;'
    GET_ALBUM_ARTIST_UPDATES_SQL = 'SELECT track_id, album_artist FROM album_artist_updates;'
    GET_GENRE_UPDATES_SQL = 'SELECT track_id, genre FROM genre_updates;'
    GET_YEAR_UPDATES_SQL = 'SELECT track_id, year FROM year_updates;'
    GET_START_UPDATES_SQL = 'SELECT track_id, start FROM start_updates;'
    GET_FINISH_UPDATES_SQL = 'SELECT track_id, finish FROM finish_updates;'

    CREATE_GENRES_SQL = <<-SQL
      CREATE TABLE genres (
        id SERIAL,
        name TEXT
      );
    SQL

    CREATE_ARTISTS_SQL = <<-SQL
      CREATE TABLE artists (
        id SERIAL,
        name TEXT,
        sort_name TEXT
      );
    SQL

    CREATE_ALBUMS_SQL = <<-SQL
      CREATE TABLE albums (
        id SERIAL,
        name TEXT,
        sort_name TEXT
      );
    SQL

    CREATE_TRACKS_SQL = <<-SQL
      CREATE TABLE tracks (
        id CHAR(16) PRIMARY KEY,
        name TEXT,
        sort_name TEXT,
        artist_id INTEGER,
        album_artist_id INTEGER,
        album_id INTEGER,
        genre_id INTEGER,
        year INTEGER,
        duration REAL,
        start REAL,
        finish REAL,
        track_number INTEGER,
        disc_number INTEGER,
        play_count INTEGER,
        rating INTEGER,
        ext TEXT,
        file TEXT,
        file_md5 CHAR(32),
        artwork_filename CHAR(36)
      );
    SQL

    CREATE_PLAYLISTS_SQL = <<-SQL
      CREATE TABLE playlists (
        id CHAR(16),
        name TEXT,
        is_library INTEGER,
        parent_id VARCHAR(16)
      );
    SQL

    CREATE_PLAYLIST_TRACK_SQL = <<-SQL
      CREATE TABLE playlist_tracks (
        playlist_id CHAR(16),
        track_id CHAR(16)
      );
    SQL

    CREATE_PLAYS_SQL = <<-SQL
      CREATE TABLE plays (
        track_id CHAR(16)
      );
    SQL

    CREATE_RATING_UPDATES_SQL = <<-SQL
      CREATE TABLE rating_updates (
        track_id CHAR(16),
        rating INTEGER
      );
    SQL

    CREATE_NAME_UPDATES_SQL = <<-SQL
      CREATE TABLE name_updates (
        track_id CHAR(16),
        name TEXT
      );
    SQL

    CREATE_ARTIST_UPDATES_SQL = <<-SQL
      CREATE TABLE artist_updates (
        track_id CHAR(16),
        artist TEXT
      );
    SQL

    CREATE_ALBUM_UPDATES_SQL = <<-SQL
      CREATE TABLE album_updates (
        track_id CHAR(16),
        album TEXT
      );
    SQL

    CREATE_ALBUM_ARTIST_UPDATES_SQL = <<-SQL
      CREATE TABLE album_artist_updates (
        track_id CHAR(16),
        album_artist TEXT
      );
    SQL

    CREATE_GENRE_UPDATES_SQL = <<-SQL
      CREATE TABLE genre_updates (
        track_id CHAR(16),
        genre TEXT
      );
    SQL

    CREATE_YEAR_UPDATES_SQL = <<-SQL
      CREATE TABLE year_updates (
        track_id CHAR(16),
        year INTEGER
      );
    SQL

    CREATE_START_UPDATES_SQL = <<-SQL
      CREATE TABLE start_updates (
        track_id CHAR(16),
        start REAL
      );
    SQL

    CREATE_FINISH_UPDATES_SQL = <<-SQL
      CREATE TABLE finish_updates (
        track_id CHAR(16),
        finish REAL
      );
    SQL

    CREATE_LIBRARY_METADATA_SQL = <<-SQL
      CREATE TABLE library_metadata (
        total_file_size BIGINT
      );
    SQL

    CREATE_EXPORT_FINISHED_SQL = <<-SQL
      CREATE TABLE export_finished (
        finished_at TIMESTAMP
      );
    SQL

    GENRE_SQL = 'INSERT INTO genres (name) VALUES ($1) RETURNING id;'

    ARTIST_SQL = 'INSERT INTO artists (name, sort_name) VALUES ($1,$2) RETURNING id;'

    ALBUM_SQL = 'INSERT INTO albums (name, sort_name) VALUES ($1,$2) RETURNING id;'

    TRACK_SQL = <<-SQL
      INSERT INTO tracks (id, name, sort_name, artist_id, album_artist_id, album_id, genre_id, year, duration, start, finish,
        track_number, disc_number, play_count, rating, ext, file, file_md5, artwork_filename) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19);
    SQL

    PLAYLIST_SQL = 'INSERT INTO playlists (id, name, is_library, parent_id) VALUES ($1,$2,$3,$4);'

    PLAYLIST_TRACK_SQL = 'INSERT INTO playlist_tracks (playlist_id, track_id) VALUES ($1,$2);'

    TRACK_AND_ARTIST_NAME_SQL = 'SELECT tracks.name, artists.name FROM tracks, artists WHERE tracks.id=$1 AND tracks.artist_id=artists.id;'

    LIBRARY_METADATA_SQL = 'INSERT INTO library_metadata (total_file_size) VALUES ($1)'

    EXPORT_FINISHED_SQL = 'INSERT INTO export_finished (finished_at) VALUES (current_timestamp)'

    def initialize(database_username, database_name)
      @database_name = database_name

      @db_connection_options = { user: database_username, dbname: @database_name }
      @postgres_connection_options = { user: database_username, dbname: 'postgres' }
      if ENV['CI']
        @db_connection_options[:host] = 'localhost'
        @postgres_connection_options[:host] = 'localhost'
        @db_connection_options[:password] = 'ci'
        @postgres_connection_options[:password] = 'ci'
      end

      @db = PG.connect(@db_connection_options)

      @genres = {}
      @artists = {}
      @albums = {}
    end

    def get_plays
      @db.exec(GET_PLAYS_SQL).values.flatten
    end

    def get_ratings
      @db.exec(GET_RATING_UPDATES_SQL).values
    end

    def get_name_updates
      @db.exec(GET_NAME_UPDATES_SQL).values
    end

    def get_artist_updates
      @db.exec(GET_ARTIST_UPDATES_SQL).values
    end

    def get_album_updates
      @db.exec(GET_ALBUM_UPDATES_SQL).values
    end

    def get_album_artist_updates
      @db.exec(GET_ALBUM_ARTIST_UPDATES_SQL).values
    end

    def get_genre_updates
      @db.exec(GET_GENRE_UPDATES_SQL).values
    end

    def get_year_updates
      @db.exec(GET_YEAR_UPDATES_SQL).values
    end

    def get_start_updates
      @db.exec(GET_START_UPDATES_SQL).values
    end

    def get_finish_updates
      @db.exec(GET_FINISH_UPDATES_SQL).values
    end

    def get_track_and_artist_name(id)
      @db.exec_params(TRACK_AND_ARTIST_NAME_SQL, [id]).values.first
    end

    def clean_and_rebuild
      @db.close

      db = PG.connect(@postgres_connection_options)
      database_exists = db.exec(DATABASE_EXISTS_SQL).values.flatten.any? { |name| name == @database_name }
      db.exec(DROP_DATABASE_SQL % @database_name) if database_exists

      db.exec(format(CREATE_DATABASE_SQL, @database_name))
      db.close

      @db = PG.connect(@db_connection_options)
      build_tables
    end

    def create_track(track)
      genre = genre_id(track.genre)
      artist = artist_id(track.artist, track.sort_artist)
      album_artist = album_artist_id(track.album_artist, track.sort_album_artist)
      album = album_id(track.album, track.sort_album)

      @db.exec_params(TRACK_SQL, [track.id, track.name, track.sort_name, artist, album_artist, album, genre, track.year,
                                  track.duration, track.start, track.finish, track.track_number, track.disc_number, track.play_count,
                                  track.rating, track.ext, track.file, track.track_file_md5, track.artwork_filename])
    end

    def create_playlist(playlist)
      @db.exec_params(PLAYLIST_SQL, [playlist.id, playlist.name, playlist.is_library, playlist.parent_id])
      playlist.tracks.each { |track_id| @db.exec_params(PLAYLIST_TRACK_SQL, [playlist.id, track_id]) }
    end

    def set_library_metadata(total_size)
      @db.exec_params(LIBRARY_METADATA_SQL, [total_size])
    end

    def set_export_finished
      @db.exec(EXPORT_FINISHED_SQL)
    end

    private

    def build_tables
      @db.exec(CREATE_GENRES_SQL)
      @db.exec(CREATE_ARTISTS_SQL)
      @db.exec(CREATE_ALBUMS_SQL)
      @db.exec(CREATE_TRACKS_SQL)
      @db.exec(CREATE_PLAYLISTS_SQL)
      @db.exec(CREATE_PLAYLIST_TRACK_SQL)
      @db.exec(CREATE_PLAYS_SQL)
      @db.exec(CREATE_RATING_UPDATES_SQL)
      @db.exec(CREATE_NAME_UPDATES_SQL)
      @db.exec(CREATE_ARTIST_UPDATES_SQL)
      @db.exec(CREATE_ALBUM_UPDATES_SQL)
      @db.exec(CREATE_ALBUM_ARTIST_UPDATES_SQL)
      @db.exec(CREATE_GENRE_UPDATES_SQL)
      @db.exec(CREATE_YEAR_UPDATES_SQL)
      @db.exec(CREATE_START_UPDATES_SQL)
      @db.exec(CREATE_FINISH_UPDATES_SQL)
      @db.exec(CREATE_LIBRARY_METADATA_SQL)
      @db.exec(CREATE_EXPORT_FINISHED_SQL)
    end

    def genre_id(name)
      @genres[name] || create_genre(name)
    end

    def create_genre(name)
      result = @db.exec_params(GENRE_SQL, [name])
      @genres[name] = result[0]['id']
    end

    def artist_id(name, sort_name)
      @artists[name] || create_artist(name, sort_name)
    end

    def album_artist_id(name, sort_name)
      return nil if name.empty?

      @artists[name] || create_artist(name, sort_name)
    end

    def create_artist(name, sort_name)
      result = @db.exec_params(ARTIST_SQL, [name, sort_name])
      @artists[name] = result[0]['id']
    end

    def album_id(name, sort_name)
      return nil if name.empty?

      @albums[name] || create_album(name, sort_name)
    end

    def create_album(name, sort_name)
      result = @db.exec_params(ALBUM_SQL, [name, sort_name])
      @albums[name] = result[0]['id']
    end
  end
end
