# frozen_string_literal: true

require 'pg'

module Update
  class Database
    attr_reader :plays

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
    GET_ARTWORK_UPDATES_SQL = 'SELECT track_id, artwork_filename FROM artwork_updates;'

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

    def initialize(database_username, database_password, database_name)
      @database_name = database_name

      @db_connection_options = { user: database_username, password: database_password, dbname: @database_name }
      if ENV['CI']
        @db_connection_options[:host] = 'localhost'
        @db_connection_options[:password] = 'ci'
      end

      @db = PG.connect(@db_connection_options)
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

    def get_artwork_updates
      @db.exec(GET_ARTWORK_UPDATES_SQL).values
    end

    def get_track_and_artist_name(id)
      @db.exec_params(TRACK_AND_ARTIST_NAME_SQL, [id]).values.first
    end
  end
end
