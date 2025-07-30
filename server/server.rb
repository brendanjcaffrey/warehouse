# frozen_string_literal: true

require 'connection_pool'
require 'pg'
require 'rack/utils'
require 'sinatra/base'
require 'sinatra/namespace'
require_relative '../update/database'
require_relative '../shared/messages_pb'
require_relative '../shared/jwt'
require_relative 'helpers'
require_relative 'errors'
require_relative 'sql'

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

  set :public_folder, proc { File.join(root, '..', 'public') }

  if Config.remote?
    set :environment, :production
    set :bind, Config.env.socket_path
  else
    set :environment, :development
    set :port, Config.env.port
  end

  helpers Helpers

  get '/' do
    send_file File.join(settings.public_folder, 'index.html')
  end

  get '/music/*' do
    if authed?
      file = params['splat'][0]
      full_path = File.expand_path(File.join(Config.env.music_path, file))
      ext = File.extname(file).delete('.').downcase

      rows = query(TRACK_HAS_MUSIC_SQL, [file])
      valid_music = !rows.empty? && rows[0]['exists'] == 't'
      raise Sinatra::NotFound unless valid_music && File.exist?(full_path) && AUDIO_MIME_TYPES.key?(ext)

      if Config.remote?
        headers['X-Accel-Redirect'] = Rack::Utils.escape_path("/accel/music/#{file}")
        headers['Content-Type'] = AUDIO_MIME_TYPES[ext]
      else
        send_file(full_path, type: ext)
      end
    else
      redirect to('/')
    end
  end

  get '/artwork/*' do
    if authed?(allow_export_user: true)
      file = params['splat'][0]
      full_path = File.expand_path(File.join(Config.env.artwork_path, file))
      ext = File.extname(file).delete('.').downcase

      rows = query(TRACK_HAS_ARTWORK_SQL, [file])
      valid_artwork = !rows.empty? && rows[0]['exists'] == 't'
      raise Sinatra::NotFound unless valid_artwork && File.exist?(full_path) && IMAGE_MIME_TYPES.key?(ext)

      if Config.remote?
        headers['X-Accel-Redirect'] = Rack::Utils.escape_path("/accel/artwork/#{file}")
        headers['Content-Type'] = IMAGE_MIME_TYPES[file.split('.').last]
      else
        send_file(full_path)
      end
    else
      redirect to('/')
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
      if username.nil?
        proto(AuthResponse.new(error: NOT_AUTHED_ERROR))
      else
        token = build_jwt(username, Config.env.secret)
        proto(AuthResponse.new(token: token))
      end
    end

    get '/version' do
      username = get_validated_username
      if username.nil?
        proto(VersionResponse.new(error: NOT_AUTHED_ERROR))
      else
        rows = query(EXPORT_FINISHED_SQL)
        halt 500, 'export did not finish!' if rows.empty?
        update_time_str = query(EXPORT_FINISHED_SQL)[0]['finished_at']
        proto(VersionResponse.new(updateTimeNs: timestamp_to_ns(update_time_str)))
      end
    end

    get '/library' do
      username = get_validated_username
      if username.nil?
        proto(LibraryResponse.new(error: NOT_AUTHED_ERROR))
      else
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
                                      musicFilename: track['music_filename'].strip,
                                      artworkFilename: (track['artwork_filename'] || '').strip,
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
