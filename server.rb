require 'pg'
require 'rack/utils'
require 'sinatra/base'
require 'sinatra/namespace'
require_relative 'export/database.rb'
require_relative 'shared/messages_pb.rb'
require_relative 'shared/jwt.rb'

INVALID_USERNAME_OR_PASSWORD_ERROR = 'invalid username or password'
NOT_AUTHED_ERROR = 'not authenticated'
NOT_TRACKING_ERROR = 'not tracking user changes'
INVALID_TRACK_ERROR = 'invalid track'
INVALID_RATING_ERROR = 'invalid rating'
TRACK_FIELD_MISSING_ERROR = 'name/year/artist/genre cannot be empty'
INVALID_YEAR_ERROR = 'invalid year'

GENRE_SQL = 'SELECT id, name FROM genres;'
ARTIST_SQL = 'SELECT id, name, sort_name FROM artists;'
ALBUM_SQL = 'SELECT id, name, sort_name FROM albums;'
TRACK_SQL = <<-SQL
SELECT
    t.id, t.name, t.sort_name, t.artist_id, t.album_artist_id, t.album_id, t.genre_id, t.year,
    t.duration, t.start, t.finish, t.track_number, t.disc_number, t.play_count, t.rating, t.ext,
    t.file_md5, STRING_AGG(ta.filename, ',') AS artwork_filenames
FROM
    tracks t
LEFT JOIN
    track_artwork ta
ON
    t.id = ta.track_id
GROUP BY
    t.id;
SQL
PLAYLIST_SQL = <<-SQL
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

TRACK_INFO_SQL = 'SELECT file, ext FROM tracks WHERE id=$1;'
TRACK_EXISTS_SQL = 'SELECT COUNT(*) FROM tracks WHERE id=$1;'
ARTWORK_EXISTS_SQL = 'SELECT EXISTS(SELECT 1 FROM track_artwork WHERE filename=$1);'

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
CREATE_ARTIST_SQL = 'INSERT INTO artists (name, sort_name) VALUES ($1, \'\') RETURNING id;';
UPDATE_ARTIST_SQL = 'UPDATE tracks SET artist_id=$1 WHERE id=$2;'

DELETE_GENRE_UPDATE_SQL = 'DELETE FROM genre_updates WHERE track_id=$1;'
CREATE_GENRE_UPDATE_SQL = 'INSERT INTO genre_updates (track_id, genre) VALUES ($1, $2);'
GENRE_ID_SQL = 'SELECT id FROM genres WHERE name=$1;'
CREATE_GENRE_SQL = 'INSERT INTO genres (name) VALUES ($1) RETURNING id;';
UPDATE_GENRE_SQL = 'UPDATE tracks SET genre_id=$1 WHERE id=$2;'

DELETE_ALBUM_ARTIST_UPDATE_SQL = 'DELETE FROM album_artist_updates WHERE track_id=$1;'
CREATE_ALBUM_ARTIST_UPDATE_SQL = 'INSERT INTO album_artist_updates (track_id, album_artist) VALUES ($1, $2);'
UPDATE_ALBUM_ARTIST_SQL = 'UPDATE tracks SET album_artist_id=$1 WHERE id=$2;'

DELETE_ALBUM_UPDATE_SQL = 'DELETE FROM album_updates WHERE track_id=$1;'
CREATE_ALBUM_UPDATE_SQL = 'INSERT INTO album_updates (track_id, album) VALUES ($1, $2);'
ALBUM_ID_SQL = 'SELECT id FROM albums WHERE name=$1;'
CREATE_ALBUM_SQL = 'INSERT INTO albums (name, sort_name) VALUES ($1, \'\') RETURNING id;';
UPDATE_ALBUM_SQL = 'UPDATE tracks SET album_id=$1 WHERE id=$2;'

MIME_TYPES = {
  'mp3' => 'audio/mpeg',
  'mp4' => 'audio/mp4',
  'm4a' => 'audio/mp4',
  'aif' => 'audio/aif',
  'aiff' => 'audio/aif',
  'wav' => 'audio/wav',
  'jpg' => 'image/jpeg',
  'png' => 'image/png',
}

def convert_cols_to_ints(rows, indices)
  rows.each do |cols|
    indices.each { |idx| cols[idx] = cols[idx].to_i }
  end

  rows
end

class Server < Sinatra::Base
  register Sinatra::Namespace

  configure do
    MIME_TYPES.each do |key, value|
      mime_type key.to_sym, value
    end
  end

  set :public_folder, Proc.new { File.join(root, 'public') }

  if Config.remote?
    set :environment, :production
    set :bind, Config['socket_path']
  else
    set :environment, :development
    set :port, Config['port']
  end

  def db
    db_connection_options = { user: Config['database_username'], dbname: Config['database_name'] }
    if ENV['CI']
      db_connection_options[:host] = 'localhost'
      db_connection_options[:password] = 'ci'
    end

    if Config.use_persistent_db?
      @@db ||= PG.connect(db_connection_options)
    else
      @db ||= PG.connect(db_connection_options)
    end
  end

  def valid_username_and_password?(username, password)
    Config.vals['users'].has_key?(username) && Config.vals['users'][username]['password'] == password
  end

  def get_validated_username(allow_export_user = false)
    auth_header = request.env['HTTP_AUTHORIZATION']
    return nil if auth_header.nil? || !auth_header.start_with?('Bearer ')

    token = auth_header.gsub('Bearer ', '')
    begin
      payload, header = decode_jwt(token, Config['secret'])
    rescue
      return nil
    end

    exp = header["exp"]
    return nil if exp.nil? || Time.now > Time.at(exp.to_i)

    username = payload['username']
    valid = Config.vals['users'].has_key?(username) || (allow_export_user && username == 'export_driver_update_library')
    return nil unless valid
    username
  end

  def is_authed?(allow_export_user = false)
    !get_validated_username(allow_export_user).nil?
  end

  def track_user_changes?(username)
    Config.vals['users'].has_key?(username) && Config.vals['users'][username]['track_updates']
  end

  def track_exists?(track_id)
    result = db.exec_params(TRACK_EXISTS_SQL, [track_id])
    count = result.num_tuples > 0 ? result.getvalue(0, 0).to_i : 0
    count > 0
  end

  def send_track_if_exists(db, music_path, persistent_track_id)
    file, ext = db.exec_params(TRACK_INFO_SQL, [persistent_track_id]).values.first
    if file == nil || !MIME_TYPES.has_key?(ext)
      false
    else
      if Config.remote?
        headers['X-Accel-Redirect'] = Rack::Utils.escape_path("/accel/music/#{file}")
        headers['Content-Type'] = MIME_TYPES[ext]
      else
        send_file(music_path + file, type: ext)
      end
      true
    end
  end


  get '/' do
    send_file File.join(settings.public_folder, 'index.html')
  end

  get '/tracks/*' do
    if !is_authed?
      redirect to('/')
    elsif !send_track_if_exists(db, Config['music_path'], params['splat'][0])
      raise Sinatra::NotFound
    end
  end

  get '/artwork/*' do
    if !is_authed?
      redirect to('/')
    else
      file = params['splat'][0]
      full_path = File.expand_path(File.join(Config['artwork_path'], file))
      valid_artwork = db.exec_params(ARTWORK_EXISTS_SQL, [file]).values.first.first == 't'
      raise Sinatra::NotFound unless valid_artwork && File.exist?(full_path)

      if Config.remote?
        headers['X-Accel-Redirect'] = Rack::Utils.escape_path("/accel/artwork/#{file}")
        headers['Content-Type'] = MIME_TYPES[file.split('.').last]
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
      if valid_username_and_password?(params[:username], params[:password])
        token = build_jwt(params[:username], Config['secret'])
        proto(AuthAttemptResponse.new(token: token))
      else
        proto(AuthAttemptResponse.new(error: INVALID_USERNAME_OR_PASSWORD_ERROR))
      end
    end

    get '/auth' do
      proto(AuthQueryResponse.new(isAuthed: is_authed?))
    end

    get '/library' do
      username = get_validated_username
      if !username.nil?
        library = Library.new(trackUserChanges: track_user_changes?(username))

        db.exec(GENRE_SQL).values.each do |genre|
          library.genres[genre[0].to_i] = Name.new(name: genre[1])
        end

        db.exec(ARTIST_SQL).values.each do |artist|
          library.artists[artist[0].to_i] = SortName.new(name: artist[1], sortName: artist[2])
        end

        db.exec(ALBUM_SQL).values.each do |album|
          library.albums[album[0].to_i] = SortName.new(name: album[1], sortName: album[2])
        end

        db.exec(TRACK_SQL).values.each do |track|
          library.tracks << Track.new(id: track[0],
                                      name: track[1],
                                      sortName: track[2],
                                      artistId: track[3].to_i,
                                      albumArtistId: track[4].to_i,
                                      albumId: track[5].to_i,
                                      genreId: track[6].to_i,
                                      year: track[7].to_i,
                                      duration: track[8].to_f,
                                      start: track[9].to_f,
                                      finish: track[10].to_f,
                                      trackNumber: track[11].to_i,
                                      discNumber: track[12].to_i,
                                      playCount: track[13].to_i,
                                      rating: track[14].to_i,
                                      ext: track[15],
                                      fileMd5: track[16].strip,
                                      artworks: (track[17] || '').split(','))
        end

        db.exec(PLAYLIST_SQL).values.each do |playlist|
          library.playlists << Playlist.new(id: playlist[0],
                                            name: playlist[1],
                                            parentId: playlist[2],
                                            isLibrary: playlist[3] == "1",
                                            trackIds: (playlist[4] || '').split(','))
        end

        library.totalFileSize = db.exec(LIBRARY_METADATA_SQL).getvalue(0, 0).to_i

        proto(LibraryResponse.new(library: library))
      else
        proto(LibraryResponse.new(error: NOT_AUTHED_ERROR))
      end
    end

    get '/updates' do
      if is_authed?(true)
        updates = Updates.new
        db.exec(Export::Database::GET_PLAYS_SQL).values.each do |play|
          updates.plays << IncrementUpdate.new(trackId: play[0])
        end
        db.exec(Export::Database::GET_RATING_UPDATES_SQL).values.each do |rating|
          updates.ratings << IntUpdate.new(trackId: rating[0], value: rating[1].to_i)
        end
        db.exec(Export::Database::GET_NAME_UPDATES_SQL).values.each do |name|
          updates.names << StringUpdate.new(trackId: name[0], value: name[1])
        end
        db.exec(Export::Database::GET_ARTIST_UPDATES_SQL).values.each do |artist|
          updates.artists << StringUpdate.new(trackId: artist[0], value: artist[1])
        end
        db.exec(Export::Database::GET_ALBUM_UPDATES_SQL).values.each do |album|
          updates.albums << StringUpdate.new(trackId: album[0], value: album[1])
        end
        db.exec(Export::Database::GET_ALBUM_ARTIST_UPDATES_SQL).values.each do |album_artist|
          updates.albumArtists << StringUpdate.new(trackId: album_artist[0], value: album_artist[1])
        end
        db.exec(Export::Database::GET_GENRE_UPDATES_SQL).values.each do |genre|
          updates.genres << StringUpdate.new(trackId: genre[0], value: genre[1])
        end
        db.exec(Export::Database::GET_YEAR_UPDATES_SQL).values.each do |year|
          updates.years << IntUpdate.new(trackId: year[0], value: year[1].to_i)
        end
        db.exec(Export::Database::GET_START_UPDATES_SQL).values.each do |start|
          updates.starts << FloatUpdate.new(trackId: start[0], value: start[1].to_f)
        end
        db.exec(Export::Database::GET_FINISH_UPDATES_SQL).values.each do |finish|
          updates.finishes << FloatUpdate.new(trackId: finish[0], value: finish[1].to_f)
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
      elsif !track_user_changes?(username)
        proto(OperationResponse.new(success: false, error: NOT_TRACKING_ERROR))
      elsif !track_exists?(track_id)
        proto(OperationResponse.new(success: false, error: INVALID_TRACK_ERROR))
      else
        block.call
        proto(OperationResponse.new(success: true))
      end
    end

    post '/play/*' do
      id = params['splat'][0]
      perform_updates_if_should_track_changes(id) do
        db.exec_params(CREATE_PLAY_SQL, [id])
        db.exec_params(INCREMENT_PLAY_SQL, [id])
      end
    end

    post '/rating/*' do
      id = params['splat'][0]
      begin
        rating = Integer(params['rating'])
      rescue
        return proto(OperationResponse.new(success: false, error: INVALID_RATING_ERROR))
      end

      if rating < 0 || rating > 100
        proto(OperationResponse.new(success: false, error: INVALID_RATING_ERROR))
      else
        perform_updates_if_should_track_changes(id) do
          db.exec_params(DELETE_RATING_UPDATE_SQL, [id])
          db.exec_params(CREATE_RATING_UPDATE_SQL, [id, rating])
          db.exec_params(UPDATE_RATING_SQL, [rating, id])
        end
      end
    end

    post '/track-info/*' do
      id = params['splat'][0]

      if (params.has_key?('name') && params['name'].empty?) ||
         (params.has_key?('year') && params['year'].empty?) ||
         (params.has_key?('artist') && params['artist'].empty?) ||
         (params.has_key?('genre') && params['genre'].empty?)
        return proto(OperationResponse.new(success: false, error: TRACK_FIELD_MISSING_ERROR))
      end

      if params.has_key?('year')
        begin
          Integer(params['year'])
        rescue
          return proto(OperationResponse.new(success: false, error: INVALID_YEAR_ERROR))
        end
      end

      perform_updates_if_should_track_changes(id) do
        if name = params['name']
          db.exec_params(DELETE_NAME_UPDATE_SQL, [id])
          db.exec_params(CREATE_NAME_UPDATE_SQL, [id, name])
          db.exec_params(UPDATE_NAME_SQL, [name, id])
        end
        if year = params['year']
          db.exec_params(DELETE_YEAR_UPDATE_SQL, [id])
          db.exec_params(CREATE_YEAR_UPDATE_SQL, [id, year])
          db.exec_params(UPDATE_YEAR_SQL, [year, id])
        end
        if start = params['start']
          db.exec_params(DELETE_START_UPDATE_SQL, [id])
          db.exec_params(CREATE_START_UPDATE_SQL, [id, start])
          db.exec_params(UPDATE_START_SQL, [start, id])
        end
        if finish = params['finish']
          db.exec_params(DELETE_FINISH_UPDATE_SQL, [id])
          db.exec_params(CREATE_FINISH_UPDATE_SQL, [id, finish])
          db.exec_params(UPDATE_FINISH_SQL, [finish, id])
        end
        if artist = params['artist']
          db.exec_params(DELETE_ARTIST_UPDATE_SQL, [id])
          db.exec_params(CREATE_ARTIST_UPDATE_SQL, [id, artist])
          result = db.exec_params(ARTIST_ID_SQL, [artist])
          artist_id = result.ntuples == 0 ? nil : result.getvalue(0,0)
          if !artist_id
            artist_id = db.exec_params(CREATE_ARTIST_SQL, [artist]).getvalue(0,0)
          end
          db.exec_params(UPDATE_ARTIST_SQL, [artist_id.to_i, id])
        end
        if genre = params['genre']
          db.exec_params(DELETE_GENRE_UPDATE_SQL, [id])
          db.exec_params(CREATE_GENRE_UPDATE_SQL, [id, genre])

          result = db.exec_params(GENRE_ID_SQL, [genre])
          genre_id = result.ntuples == 0 ? nil : result.getvalue(0,0)
          if !genre_id
            genre_id = db.exec_params(CREATE_GENRE_SQL, [genre]).getvalue(0,0)
          end
          db.exec_params(UPDATE_GENRE_SQL, [genre_id.to_i, id])
        end
        if album_artist = params['album_artist']
          db.exec_params(DELETE_ALBUM_ARTIST_UPDATE_SQL, [id])
          db.exec_params(CREATE_ALBUM_ARTIST_UPDATE_SQL, [id, album_artist])
          if album_artist.empty?
            album_artist_id = nil
          else
            result = db.exec_params(ARTIST_ID_SQL, [album_artist])
            album_artist_id = result.ntuples == 0 ? nil : result.getvalue(0,0)
            if !album_artist_id
              album_artist_id = db.exec_params(CREATE_ARTIST_SQL, [album_artist]).getvalue(0,0)
            end
            album_artist_id = album_artist_id.to_i
          end
          db.exec_params(UPDATE_ALBUM_ARTIST_SQL, [album_artist_id, id])
        end
        if album = params['album']
          db.exec_params(DELETE_ALBUM_UPDATE_SQL, [id])
          db.exec_params(CREATE_ALBUM_UPDATE_SQL, [id, album])
          if album.empty?
            album_id = nil
          else
            result = db.exec_params(ALBUM_ID_SQL, [album])
            album_id = result.ntuples == 0 ? nil : result.getvalue(0,0)
            if !album_id
              album_id = db.exec_params(CREATE_ALBUM_SQL, [album]).getvalue(0,0)
            end
            album_id = album_id.to_i
          end
          db.exec_params(UPDATE_ALBUM_SQL, [album_id, id])
        end
      end
    end
  end
end
