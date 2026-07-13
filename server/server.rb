# frozen_string_literal: true

require 'connection_pool'
require 'pg'
require 'rack/utils'
require 'sinatra/base'
require 'sinatra/namespace'
require_relative '../update/database'
require_relative '../shared/messages_pb'
require_relative '../shared/jwt'
require_relative 'bundles'
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
    mime_type :tar, 'application/x-tar'
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

  get '/bundle/:id' do
    if authed?
      id = params[:id]
      valid_id = id.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
      full_path = File.join(Config.env.bundles_path, "#{id}.tar")
      raise Sinatra::NotFound unless valid_id && File.exist?(full_path)

      if Config.remote?
        headers['X-Accel-Redirect'] = "/accel/bundles/#{id}.tar"
        headers['Content-Type'] = 'application/x-tar'
        ''
      else
        send_file(full_path, type: :tar)
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

    # playlist_ids trims the library for the watch: only those playlists (with
    # folder ancestry dropped) and the tracks that belong to them survive
    def build_library(username, playlist_ids: nil)
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

      kept_track_ids = nil
      playlists = query(PLAYLIST_SQL)
      unless playlist_ids.nil?
        playlists = playlists.select { |playlist| playlist_ids.include?(playlist['id']) }
        playlists.each { |playlist| playlist['parent_id'] = '' }
        kept_track_ids = playlists.flat_map { |playlist| (playlist['track_ids'] || '').split(',') }.to_set
      end

      query(TRACK_SQL).each do |track|
        next unless kept_track_ids.nil? || kept_track_ids.include?(track['id'])

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

      playlists.each do |playlist|
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
      library
    end

    get '/library' do
      username = get_validated_username
      if username.nil?
        proto(LibraryResponse.new(error: NOT_AUTHED_ERROR))
      else
        proto(LibraryResponse.new(library: build_library(username)))
      end
    end

    post '/library' do
      username = get_validated_username
      return proto(LibraryResponse.new(error: NOT_AUTHED_ERROR)) if username.nil?

      begin
        req = LibraryRequest.decode(request.body.read)
      rescue Google::Protobuf::ParseError
        return proto(LibraryResponse.new(error: INVALID_REQUEST_ERROR))
      end

      proto(LibraryResponse.new(library: build_library(username, playlist_ids: req.playlistIds.to_a)))
    end

    post '/bundle' do
      return proto(BundleResponse.new(error: NOT_AUTHED_ERROR)) unless authed?

      begin
        req = BundleRequest.decode(request.body.read)
      rescue Google::Protobuf::ParseError
        return proto(BundleResponse.new(error: INVALID_REQUEST_ERROR))
      end

      music = req.type == :MUSIC
      type = music ? :music : :artwork
      filenames = req.filenames.to_a
      return proto(BundleResponse.new(error: INVALID_REQUEST_ERROR)) if filenames.empty?
      return proto(BundleResponse.new(error: BUNDLE_TOO_LARGE_ERROR)) if filenames.size > Bundles::CAPS[type]

      mime_types = music ? AUDIO_MIME_TYPES : IMAGE_MIME_TYPES
      valid_names = filenames.all? do |filename|
        !filename.include?('/') && mime_types.key?(File.extname(filename).delete('.').downcase)
      end
      return proto(BundleResponse.new(error: INVALID_FILENAME_ERROR)) unless valid_names

      # a filename the database doesn't know about means the client's library
      # is stale; reject the whole request so it refetches instead of retrying
      sql = music ? MATCHING_MUSIC_FILENAMES_SQL : MATCHING_ARTWORK_FILENAMES_SQL
      encoded = PG::TextEncoder::Array.new.encode(filenames)
      known = query(sql, [encoded]).flat_map(&:values).to_set
      return proto(BundleResponse.new(error: INVALID_FILENAME_ERROR)) unless filenames.all? { |filename| known.include?(filename) }

      source_path = music ? Config.env.music_path : Config.env.artwork_path
      all_exist = filenames.all? { |filename| File.exist?(File.join(source_path, filename)) }
      return proto(BundleResponse.new(error: MISSING_FILE_ERROR)) unless all_exist

      uuid = Bundles.create(type: type, filenames: filenames, source_path: source_path, bundles_path: Config.env.bundles_path)
      proto(BundleResponse.new(id: uuid))
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

    post '/track/*' do
      id = params['splat'][0]

      begin
        update = TrackUpdate.decode(request.body.read)
      rescue Google::Protobuf::ParseError
        return proto(OperationResponse.new(success: false, error: INVALID_REQUEST_ERROR))
      end

      if (update.has_name? && update.name.empty?) ||
         (update.has_year? && update.year.zero?) ||
         (update.has_artist? && update.artist.empty?) ||
         (update.has_genre? && update.genre.empty?)
        return proto(OperationResponse.new(success: false, error: TRACK_FIELD_MISSING_ERROR))
      end

      return proto(OperationResponse.new(success: false, error: INVALID_RATING_ERROR)) if update.has_rating? && (update.rating.negative? || update.rating > 100)

      return proto(OperationResponse.new(success: false, error: MISSING_FILE_ERROR)) if update.has_artwork? && !update.artwork.empty? && !File.exist?(File.join(Config.env.artwork_path, update.artwork))

      perform_updates_if_should_track_changes(id) do |conn|
        if update.has_name?
          conn.exec_params(DELETE_NAME_UPDATE_SQL, [id])
          conn.exec_params(CREATE_NAME_UPDATE_SQL, [id, update.name])
          conn.exec_params(UPDATE_NAME_SQL, [update.name, id])
        end
        if update.has_year?
          conn.exec_params(DELETE_YEAR_UPDATE_SQL, [id])
          conn.exec_params(CREATE_YEAR_UPDATE_SQL, [id, update.year])
          conn.exec_params(UPDATE_YEAR_SQL, [update.year, id])
        end
        if update.has_start?
          conn.exec_params(DELETE_START_UPDATE_SQL, [id])
          conn.exec_params(CREATE_START_UPDATE_SQL, [id, update.start])
          conn.exec_params(UPDATE_START_SQL, [update.start, id])
        end
        if update.has_finish?
          conn.exec_params(DELETE_FINISH_UPDATE_SQL, [id])
          conn.exec_params(CREATE_FINISH_UPDATE_SQL, [id, update.finish])
          conn.exec_params(UPDATE_FINISH_SQL, [update.finish, id])
        end
        if update.has_artist?
          conn.exec_params(DELETE_ARTIST_UPDATE_SQL, [id])
          conn.exec_params(CREATE_ARTIST_UPDATE_SQL, [id, update.artist])
          result = conn.exec_params(ARTIST_ID_SQL, [update.artist])
          artist_id = result.ntuples.zero? ? nil : result.getvalue(0, 0)
          artist_id ||= conn.exec_params(CREATE_ARTIST_SQL, [update.artist]).getvalue(0, 0)
          conn.exec_params(UPDATE_ARTIST_SQL, [artist_id.to_i, id])
        end
        if update.has_genre?
          conn.exec_params(DELETE_GENRE_UPDATE_SQL, [id])
          conn.exec_params(CREATE_GENRE_UPDATE_SQL, [id, update.genre])

          result = conn.exec_params(GENRE_ID_SQL, [update.genre])
          genre_id = result.ntuples.zero? ? nil : result.getvalue(0, 0)
          genre_id ||= conn.exec_params(CREATE_GENRE_SQL, [update.genre]).getvalue(0, 0)
          conn.exec_params(UPDATE_GENRE_SQL, [genre_id.to_i, id])
        end
        if update.has_albumArtist?
          album_artist = update.albumArtist
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
        if update.has_album?
          conn.exec_params(DELETE_ALBUM_UPDATE_SQL, [id])
          conn.exec_params(CREATE_ALBUM_UPDATE_SQL, [id, update.album])
          if update.album.empty?
            album_id = nil
          else
            result = conn.exec_params(ALBUM_ID_SQL, [update.album])
            album_id = result.ntuples.zero? ? nil : result.getvalue(0, 0)
            album_id ||= conn.exec_params(CREATE_ALBUM_SQL, [update.album]).getvalue(0, 0)
            album_id = album_id.to_i
          end
          conn.exec_params(UPDATE_ALBUM_SQL, [album_id, id])
        end
        if update.has_artwork?
          artwork = update.artwork.empty? ? nil : update.artwork
          conn.exec_params(DELETE_ARTWORK_UPDATE_SQL, [id])
          conn.exec_params(CREATE_ARTWORK_UPDATE_SQL, [id, artwork])
          conn.exec_params(UPDATE_ARTWORK_SQL, [artwork, id])
        end
        if update.has_rating?
          conn.exec_params(DELETE_RATING_UPDATE_SQL, [id])
          conn.exec_params(CREATE_RATING_UPDATE_SQL, [id, update.rating])
          conn.exec_params(UPDATE_RATING_SQL, [update.rating, id])
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
