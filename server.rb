# frozen_string_literal: true

require 'connection_pool'
require 'pg'
require 'rack/utils'
require 'sinatra/base'
require 'sinatra/namespace'
require_relative 'update/database'
require_relative 'shared/messages_pb'
require_relative 'shared/jwt'

INVALID_USERNAME_OR_PASSWORD_ERROR = 'invalid username or password'
NOT_AUTHED_ERROR = 'not authenticated'
NOT_TRACKING_ERROR = 'not tracking user changes'
INVALID_TRACK_ERROR = 'invalid track'
INVALID_RATING_ERROR = 'invalid rating'
TRACK_FIELD_MISSING_ERROR = 'name/year/artist/genre cannot be empty'
INVALID_YEAR_ERROR = 'invalid year'
MISSING_FILE_ERROR = 'missing file'
INVALID_MIME_ERROR = 'invalid file type'
INVALID_MD5_ERROR = 'file name and contents mismatch'

GENRE_SQL = 'SELECT id, name FROM genres;'
ARTIST_SQL = 'SELECT id, name, sort_name FROM artists;'
ALBUM_SQL = 'SELECT id, name, sort_name FROM albums;'
TRACK_SQL = <<~SQL
  SELECT
      t.id, t.name, t.sort_name, t.artist_id, t.album_artist_id, t.album_id, t.genre_id, t.year,
      t.duration, t.start, t.finish, t.track_number, t.disc_number, t.play_count, t.rating, t.ext,
      t.file_md5, t.artwork_filename, STRING_AGG(pt.playlist_id, ',') AS playlist_ids
  FROM
      tracks t
  LEFT JOIN
      playlist_tracks pt
  ON
      t.id = pt.track_id
  GROUP BY
      t.id
SQL
LIBRARY_PLAYLIST_IDS_SQL = 'SELECT id FROM playlists WHERE is_library = 1;'
PLAYLIST_SQL = <<~SQL
  SELECT
      p.id, p.name, p.parent_id, p.is_library,
      STRING_AGG(pt.track_id, ',') AS track_ids
  FROM
      playlists p
  LEFT JOIN
      playlist_tracks pt
  ON
      p.id = pt.playlist_id
  GROUP BY
      p.id, p.name, p.parent_id, p.is_library;
SQL
LIBRARY_METADATA_SQL = 'SELECT total_file_size FROM library_metadata;'
EXPORT_FINISHED_SQL = 'SELECT finished_at FROM export_finished;'

TRACK_EXT_SQL = 'SELECT ext FROM tracks WHERE file_md5=$1;'
TRACK_EXISTS_SQL = 'SELECT COUNT(*) FROM tracks WHERE id=$1;'
TRACK_HAS_ARTWORK_SQL = 'SELECT EXISTS(SELECT 1 FROM tracks WHERE artwork_filename=$1);'

CREATE_PLAY_SQL = 'INSERT INTO plays (track_id) VALUES ($1);'
INCREMENT_PLAY_SQL = 'UPDATE tracks SET play_count=play_count+1 WHERE id=$1;'

DELETE_RATING_UPDATE_SQL = 'DELETE FROM rating_updates WHERE track_id=$1;'
CREATE_RATING_UPDATE_SQL = 'INSERT INTO rating_updates (track_id, rating) VALUES ($1, $2);'
UPDATE_RATING_SQL = 'UPDATE tracks SET rating=$1 WHERE id=$2;'

DELETE_NAME_UPDATE_SQL = 'DELETE FROM name_updates WHERE track_id=$1;'
CREATE_NAME_UPDATE_SQL = 'INSERT INTO name_updates (track_id, name) VALUES ($1, $2);'
UPDATE_NAME_SQL = 'UPDATE tracks SET name=$1 WHERE id=$2;'

DELETE_YEAR_UPDATE_SQL = 'DELETE FROM year_updates WHERE track_id=$1;'
CREATE_YEAR_UPDATE_SQL = 'INSERT INTO year_updates (track_id, year) VALUES ($1, $2);'
UPDATE_YEAR_SQL = 'UPDATE tracks SET year=$1 WHERE id=$2;'

DELETE_START_UPDATE_SQL = 'DELETE FROM start_updates WHERE track_id=$1;'
CREATE_START_UPDATE_SQL = 'INSERT INTO start_updates (track_id, start) VALUES ($1, $2);'
UPDATE_START_SQL = 'UPDATE tracks SET start=$1 WHERE id=$2;'

DELETE_FINISH_UPDATE_SQL = 'DELETE FROM finish_updates WHERE track_id=$1;'
CREATE_FINISH_UPDATE_SQL = 'INSERT INTO finish_updates (track_id, finish) VALUES ($1, $2);'
UPDATE_FINISH_SQL = 'UPDATE tracks SET finish=$1 WHERE id=$2;'

DELETE_ARTIST_UPDATE_SQL = 'DELETE FROM artist_updates WHERE track_id=$1;'
CREATE_ARTIST_UPDATE_SQL = 'INSERT INTO artist_updates (track_id, artist) VALUES ($1, $2);'
ARTIST_ID_SQL = 'SELECT id FROM artists WHERE name=$1;'
CREATE_ARTIST_SQL = 'INSERT INTO artists (name, sort_name) VALUES ($1, \'\') RETURNING id;'
UPDATE_ARTIST_SQL = 'UPDATE tracks SET artist_id=$1 WHERE id=$2;'

DELETE_GENRE_UPDATE_SQL = 'DELETE FROM genre_updates WHERE track_id=$1;'
CREATE_GENRE_UPDATE_SQL = 'INSERT INTO genre_updates (track_id, genre) VALUES ($1, $2);'
GENRE_ID_SQL = 'SELECT id FROM genres WHERE name=$1;'
CREATE_GENRE_SQL = 'INSERT INTO genres (name) VALUES ($1) RETURNING id;'
UPDATE_GENRE_SQL = 'UPDATE tracks SET genre_id=$1 WHERE id=$2;'

DELETE_ALBUM_ARTIST_UPDATE_SQL = 'DELETE FROM album_artist_updates WHERE track_id=$1;'
CREATE_ALBUM_ARTIST_UPDATE_SQL = 'INSERT INTO album_artist_updates (track_id, album_artist) VALUES ($1, $2);'
UPDATE_ALBUM_ARTIST_SQL = 'UPDATE tracks SET album_artist_id=$1 WHERE id=$2;'

DELETE_ALBUM_UPDATE_SQL = 'DELETE FROM album_updates WHERE track_id=$1;'
CREATE_ALBUM_UPDATE_SQL = 'INSERT INTO album_updates (track_id, album) VALUES ($1, $2);'
ALBUM_ID_SQL = 'SELECT id FROM albums WHERE name=$1;'
CREATE_ALBUM_SQL = 'INSERT INTO albums (name, sort_name) VALUES ($1, \'\') RETURNING id;'
UPDATE_ALBUM_SQL = 'UPDATE tracks SET album_id=$1 WHERE id=$2;'

DELETE_ARTWORK_UPDATE_SQL = 'DELETE FROM artwork_updates WHERE track_id=$1;'
CREATE_ARTWORK_UPDATE_SQL = 'INSERT INTO artwork_updates (track_id, artwork_filename) VALUES ($1, $2);'
UPDATE_ARTWORK_SQL = 'UPDATE tracks SET artwork_filename=$1 WHERE id=$2;'

UPDATE_EXPORT_FINISHED_SQL = 'UPDATE export_finished SET finished_at=current_timestamp;'

IMAGE_MIME_TYPES = {
  'jpg' => 'image/jpeg',
  'png' => 'image/png'
}.freeze

AUDIO_MIME_TYPES = {
  'mp3' => 'audio/mpeg',
  'mp4' => 'audio/mp4',
  'm4a' => 'audio/mp4',
  'aif' => 'audio/aif',
  'aiff' => 'audio/aif',
  'wav' => 'audio/wav'
}.freeze

def convert_cols_to_ints(rows, indices)
  rows.each do |cols|
    indices.each { |idx| cols[idx] = cols[idx].to_i }
  end

  rows
end

def timestamp_to_ns(time_str)
  time = Time.strptime("#{time_str} UTC", '%Y-%m-%d %H:%M:%S.%N %Z')
  time.to_i * 1_000_000_000 + time.nsec
end

DB_POOL = ConnectionPool.new(size: 5, timeout: 5) do
  PG.connect(
    dbname: Config.env.database_name,
    user: Config.env.database_username,
    password: Config.env.database_password,
    host: Config.env.database_host,
    port: Config.env.database_port
  ).tap do |conn|
    conn.exec("SET TIME ZONE 'UTC'")
  end
end

class Server < Sinatra::Base
  register Sinatra::Namespace

  configure do
    IMAGE_MIME_TYPES.each do |key, value|
      mime_type key.to_sym, value
    end
    AUDIO_MIME_TYPES.each do |key, value|
      mime_type key.to_sym, value
    end
  end

  set :public_folder, proc { File.join(root, 'public') }

  if Config.remote?
    set :environment, :production
    set :bind, Config.env.socket_path
  else
    set :environment, :development
    set :port, Config.env.port
  end

  def get_validated_username(allow_export_user: false)
    auth_header = request.env['HTTP_AUTHORIZATION']
    return nil if auth_header.nil? || !auth_header.start_with?('Bearer ')

    token = auth_header.gsub('Bearer ', '')
    begin
      payload, header = decode_jwt(token, Config.env.secret)
    rescue StandardError
      return nil
    end

    exp = header['exp']
    return nil if exp.nil? || Time.now > Time.at(exp.to_i)

    username = payload['username']
    valid = Config.valid_username?(username) || (allow_export_user && username == 'export_driver_update_library')
    return nil unless valid

    username
  end

  def authed?(allow_export_user: false)
    !get_validated_username(allow_export_user: allow_export_user).nil?
  end

  def track_exists?(track_id)
    rows = query(TRACK_EXISTS_SQL, [track_id])
    count = rows.empty? ? 0 : rows[0]['count'].to_i
    count.positive?
  end

  helpers do
    def query(sql, params = [])
      result = nil
      DB_POOL.with do |conn|
        result = conn.exec_params(sql, params)
      end
      result.to_a
    end

    def update_query(sql, params = [])
      result = nil
      DB_POOL.with do |conn|
        result = conn.exec_params(sql, params)
      end
      result.cmd_tuples
    end
  end

  get '/' do
    send_file File.join(settings.public_folder, 'index.html')
  end

  get '/tracks/*' do
    if !authed?
      redirect to('/')
    else
      file = params['splat'][0]
      rows = query(TRACK_EXT_SQL, [file])
      raise Sinatra::NotFound if rows.empty? || !AUDIO_MIME_TYPES.key?(rows[0]['ext'])

      ext = rows[0]['ext']
      filename = "#{file}.#{ext}"
      full_path = File.expand_path(File.join(Config.env.music_path, filename))
      raise Sinatra::NotFound unless File.exist?(full_path)

      if Config.remote?
        headers['X-Accel-Redirect'] = Rack::Utils.escape_path("/accel/music/#{filename}")
        headers['Content-Type'] = AUDIO_MIME_TYPES[ext]
      else
        send_file(full_path, type: ext)
      end

    end
  end

  get '/artwork/*' do
    if !authed?(allow_export_user: true)
      redirect to('/')
    else
      file = params['splat'][0]
      full_path = File.expand_path(File.join(Config.env.artwork_path, file))
      rows = query(TRACK_HAS_ARTWORK_SQL, [file])
      valid_artwork = !rows.empty? && rows[0]['exists'] == 't'
      raise Sinatra::NotFound unless valid_artwork && File.exist?(full_path)

      if Config.remote?
        headers['X-Accel-Redirect'] = Rack::Utils.escape_path("/accel/artwork/#{file}")
        headers['Content-Type'] = IMAGE_MIME_TYPES[file.split('.').last]
      else
        send_file(full_path)
      end
    end
  end

  namespace '/api' do
    def proto(msg)
      content_type 'application/octet-stream'
      msg.to_proto
    end

    post '/auth' do
      content_type 'application/octet-stream'
      if Config.valid_username_and_password?(params[:username], params[:password])
        token = build_jwt(params[:username], Config.env.secret)
        proto(AuthResponse.new(token: token))
      else
        proto(AuthResponse.new(error: INVALID_USERNAME_OR_PASSWORD_ERROR))
      end
    end

    put '/auth' do
      content_type 'application/octet-stream'
      username = get_validated_username
      if !username.nil?
        token = build_jwt(username, Config.env.secret)
        proto(AuthResponse.new(token: token))
      else
        proto(AuthResponse.new(error: NOT_AUTHED_ERROR))
      end
    end

    get '/version' do
      username = get_validated_username
      if !username.nil?
        rows = query(EXPORT_FINISHED_SQL)
        halt 500, 'export did not finish!' if rows.empty?
        update_time_str = query(EXPORT_FINISHED_SQL)[0]['finished_at']
        proto(VersionResponse.new(updateTimeNs: timestamp_to_ns(update_time_str)))
      else
        proto(VersionResponse.new(error: NOT_AUTHED_ERROR))
      end
    end

    get '/library' do
      username = get_validated_username
      if !username.nil?
        library = Library.new(trackUserChanges: Config.track_user_changes?(username))
        library_playlist_ids = query(LIBRARY_PLAYLIST_IDS_SQL).map(&:values).flatten

        query(GENRE_SQL).each do |genre|
          library.genres[genre['id'].to_i] = Name.new(name: genre['name'])
        end

        query(ARTIST_SQL).each do |artist|
          library.artists[artist['id'].to_i] = SortName.new(name: artist['name'], sortName: artist['sort_name'])
        end

        query(ALBUM_SQL).each do |album|
          library.albums[album['id'].to_i] = SortName.new(name: album['name'], sortName: album['sort_name'])
        end

        query(TRACK_SQL).each do |track|
          library.tracks << Track.new(id: track['id'],
                                      name: track['name'],
                                      sortName: track['sort_name'],
                                      artistId: track['artist_id'].to_i,
                                      albumArtistId: track['album_artist_id'].to_i,
                                      albumId: track['album_id'].to_i,
                                      genreId: track['genre_id'].to_i,
                                      year: track['year'].to_i,
                                      duration: track['duration'].to_f,
                                      start: track['start'].to_f,
                                      finish: track['finish'].to_f,
                                      trackNumber: track['track_number'].to_i,
                                      discNumber: track['disc_number'].to_i,
                                      playCount: track['play_count'].to_i,
                                      rating: track['rating'].to_i,
                                      ext: track['ext'],
                                      fileMd5: track['file_md5'].strip,
                                      artworkFilename: track['artwork_filename'],
                                      playlistIds: (track['playlist_ids'] || '').split(',').concat(library_playlist_ids))
        end

        query(PLAYLIST_SQL).each do |playlist|
          library.playlists << Playlist.new(id: playlist['id'],
                                            name: playlist['name'],
                                            parentId: playlist['parent_id'],
                                            isLibrary: playlist['is_library'] == '1',
                                            trackIds: (playlist['track_ids'] || '').split(','))
        end

        metadata_rows = query(LIBRARY_METADATA_SQL)
        export_finished_rows = query(EXPORT_FINISHED_SQL)
        halt 500, 'export did not finish!' if metadata_rows.empty? || export_finished_rows.empty?

        library.totalFileSize = metadata_rows[0]['total_file_size'].to_i
        library.updateTimeNs = timestamp_to_ns(export_finished_rows[0]['finished_at'])
        proto(LibraryResponse.new(library: library))
      else
        proto(LibraryResponse.new(error: NOT_AUTHED_ERROR))
      end
    end

    get '/updates' do
      if authed?(allow_export_user: true)
        updates = Updates.new
        query(Update::Database::GET_PLAYS_SQL).each do |play|
          updates.plays << IncrementUpdate.new(trackId: play['track_id'])
        end
        query(Update::Database::GET_RATING_UPDATES_SQL).each do |rating|
          updates.ratings << IntUpdate.new(trackId: rating['track_id'], value: rating['rating'].to_i)
        end
        query(Update::Database::GET_NAME_UPDATES_SQL).each do |name|
          updates.names << StringUpdate.new(trackId: name['track_id'], value: name['name'])
        end
        query(Update::Database::GET_ARTIST_UPDATES_SQL).each do |artist|
          updates.artists << StringUpdate.new(trackId: artist['track_id'], value: artist['artist'])
        end
        query(Update::Database::GET_ALBUM_UPDATES_SQL).each do |album|
          updates.albums << StringUpdate.new(trackId: album['track_id'], value: album['album'])
        end
        query(Update::Database::GET_ALBUM_ARTIST_UPDATES_SQL).each do |album_artist|
          updates.albumArtists << StringUpdate.new(trackId: album_artist['track_id'], value: album_artist['album_artist'])
        end
        query(Update::Database::GET_GENRE_UPDATES_SQL).each do |genre|
          updates.genres << StringUpdate.new(trackId: genre['track_id'], value: genre['genre'])
        end
        query(Update::Database::GET_YEAR_UPDATES_SQL).each do |year|
          updates.years << IntUpdate.new(trackId: year['track_id'], value: year['year'].to_i)
        end
        query(Update::Database::GET_START_UPDATES_SQL).each do |start|
          updates.starts << FloatUpdate.new(trackId: start['track_id'], value: start['start'].to_f)
        end
        query(Update::Database::GET_FINISH_UPDATES_SQL).each do |finish|
          updates.finishes << FloatUpdate.new(trackId: finish['track_id'], value: finish['finish'].to_f)
        end
        query(Update::Database::GET_ARTWORK_UPDATES_SQL).each do |artwork|
          updates.artworks << StringUpdate.new(trackId: artwork['track_id'], value: artwork['artwork_filename'])
        end
        proto(UpdatesResponse.new(updates: updates))
      else
        proto(UpdatesResponse.new(error: NOT_AUTHED_ERROR))
      end
    end

    def perform_updates_if_should_track_changes(track_id, &block)
      username = get_validated_username
      if username.nil?
        proto(OperationResponse.new(success: false, error: NOT_AUTHED_ERROR))
      elsif !Config.track_user_changes?(username)
        proto(OperationResponse.new(success: false, error: NOT_TRACKING_ERROR))
      elsif !track_exists?(track_id)
        proto(OperationResponse.new(success: false, error: INVALID_TRACK_ERROR))
      else
        DB_POOL.with do |conn|
          block.call(conn)
        end
        proto(OperationResponse.new(success: true))
      end
    end

    post '/play/*' do
      id = params['splat'][0]
      perform_updates_if_should_track_changes(id) do |conn|
        conn.exec_params(CREATE_PLAY_SQL, [id])
        conn.exec_params(INCREMENT_PLAY_SQL, [id])
        conn.exec(UPDATE_EXPORT_FINISHED_SQL)
      end
    end

    post '/rating/*' do
      id = params['splat'][0]
      begin
        rating = Integer(params['rating'])
      rescue StandardError
        return proto(OperationResponse.new(success: false, error: INVALID_RATING_ERROR))
      end

      if rating.negative? || rating > 100
        proto(OperationResponse.new(success: false, error: INVALID_RATING_ERROR))
      else
        perform_updates_if_should_track_changes(id) do |conn|
          conn.exec_params(DELETE_RATING_UPDATE_SQL, [id])
          conn.exec_params(CREATE_RATING_UPDATE_SQL, [id, rating])
          conn.exec_params(UPDATE_RATING_SQL, [rating, id])
          conn.exec(UPDATE_EXPORT_FINISHED_SQL)
        end
      end
    end

    post '/track-info/*' do
      id = params['splat'][0]

      if (params.key?('name') && params['name'].empty?) ||
         (params.key?('year') && params['year'].empty?) ||
         (params.key?('artist') && params['artist'].empty?) ||
         (params.key?('genre') && params['genre'].empty?)
        return proto(OperationResponse.new(success: false, error: TRACK_FIELD_MISSING_ERROR))
      end

      if params.key?('year')
        begin
          Integer(params['year'])
        rescue StandardError
          return proto(OperationResponse.new(success: false, error: INVALID_YEAR_ERROR))
        end
      end

      return proto(OperationResponse.new(success: false, error: MISSING_FILE_ERROR)) if params.key?('artwork') && params['artwork'] != '' && !File.exist?(File.join(Config.env.artwork_path, params['artwork']))

      perform_updates_if_should_track_changes(id) do |conn|
        if (name = params['name'])
          conn.exec_params(DELETE_NAME_UPDATE_SQL, [id])
          conn.exec_params(CREATE_NAME_UPDATE_SQL, [id, name])
          conn.exec_params(UPDATE_NAME_SQL, [name, id])
        end
        if (year = params['year'])
          conn.exec_params(DELETE_YEAR_UPDATE_SQL, [id])
          conn.exec_params(CREATE_YEAR_UPDATE_SQL, [id, year])
          conn.exec_params(UPDATE_YEAR_SQL, [year, id])
        end
        if (start = params['start'])
          conn.exec_params(DELETE_START_UPDATE_SQL, [id])
          conn.exec_params(CREATE_START_UPDATE_SQL, [id, start])
          conn.exec_params(UPDATE_START_SQL, [start, id])
        end
        if (finish = params['finish'])
          conn.exec_params(DELETE_FINISH_UPDATE_SQL, [id])
          conn.exec_params(CREATE_FINISH_UPDATE_SQL, [id, finish])
          conn.exec_params(UPDATE_FINISH_SQL, [finish, id])
        end
        if (artist = params['artist'])
          conn.exec_params(DELETE_ARTIST_UPDATE_SQL, [id])
          conn.exec_params(CREATE_ARTIST_UPDATE_SQL, [id, artist])
          result = conn.exec_params(ARTIST_ID_SQL, [artist])
          artist_id = result.ntuples.zero? ? nil : result.getvalue(0, 0)
          artist_id ||= conn.exec_params(CREATE_ARTIST_SQL, [artist]).getvalue(0, 0)
          conn.exec_params(UPDATE_ARTIST_SQL, [artist_id.to_i, id])
        end
        if (genre = params['genre'])
          conn.exec_params(DELETE_GENRE_UPDATE_SQL, [id])
          conn.exec_params(CREATE_GENRE_UPDATE_SQL, [id, genre])

          result = conn.exec_params(GENRE_ID_SQL, [genre])
          genre_id = result.ntuples.zero? ? nil : result.getvalue(0, 0)
          genre_id ||= conn.exec_params(CREATE_GENRE_SQL, [genre]).getvalue(0, 0)
          conn.exec_params(UPDATE_GENRE_SQL, [genre_id.to_i, id])
        end
        if (album_artist = params['album_artist'])
          conn.exec_params(DELETE_ALBUM_ARTIST_UPDATE_SQL, [id])
          conn.exec_params(CREATE_ALBUM_ARTIST_UPDATE_SQL, [id, album_artist])
          if album_artist.empty?
            album_artist_id = nil
          else
            result = conn.exec_params(ARTIST_ID_SQL, [album_artist])
            album_artist_id = result.ntuples.zero? ? nil : result.getvalue(0, 0)
            album_artist_id ||= conn.exec_params(CREATE_ARTIST_SQL, [album_artist]).getvalue(0, 0)
            album_artist_id = album_artist_id.to_i
          end
          conn.exec_params(UPDATE_ALBUM_ARTIST_SQL, [album_artist_id, id])
        end
        if (album = params['album'])
          conn.exec_params(DELETE_ALBUM_UPDATE_SQL, [id])
          conn.exec_params(CREATE_ALBUM_UPDATE_SQL, [id, album])
          if album.empty?
            album_id = nil
          else
            result = conn.exec_params(ALBUM_ID_SQL, [album])
            album_id = result.ntuples.zero? ? nil : result.getvalue(0, 0)
            album_id ||= conn.exec_params(CREATE_ALBUM_SQL, [album]).getvalue(0, 0)
            album_id = album_id.to_i
          end
          conn.exec_params(UPDATE_ALBUM_SQL, [album_id, id])
        end
        if (artwork = params['artwork'])
          artwork = nil if artwork == ''
          conn.exec_params(DELETE_ARTWORK_UPDATE_SQL, [id])
          conn.exec_params(CREATE_ARTWORK_UPDATE_SQL, [id, artwork])
          conn.exec_params(UPDATE_ARTWORK_SQL, [artwork, id])
        end
        conn.exec(UPDATE_EXPORT_FINISHED_SQL)
      end
    end

    post '/artwork' do
      username = get_validated_username
      if username.nil?
        return proto(OperationResponse.new(success: false, error: NOT_AUTHED_ERROR))
      elsif !Config.track_user_changes?(username)
        return proto(OperationResponse.new(success: false, error: NOT_TRACKING_ERROR))
      end

      return proto(OperationResponse.new(success: false, error: MISSING_FILE_ERROR)) if !params.key?(:file) || params[:file].nil? || params[:file][:tempfile].nil? || params[:file][:filename].nil?

      filename = params[:file][:filename]
      expected_md5, extension = filename.split('.')
      return proto(OperationResponse.new(success: false, error: INVALID_MIME_ERROR)) unless IMAGE_MIME_TYPES.key?(extension)

      tempfile = params[:file][:tempfile]
      md5 = Digest::MD5.file(tempfile).hexdigest
      return proto(OperationResponse.new(success: false, error: INVALID_MD5_ERROR)) if md5 != expected_md5

      out_path = File.expand_path(File.join(Config.env.artwork_path, filename))
      FileUtils.cp(tempfile.path, out_path) unless File.exist?(out_path)
      return proto(OperationResponse.new(success: true))
    end
  end
end
