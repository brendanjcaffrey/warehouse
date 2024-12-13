require 'jwt'
require 'pg'
require 'rack/utils'
require 'sinatra/base'
require 'sinatra/namespace'
require_relative 'export/database.rb'

JWT_ALGO = 'HS256'
JWT_EXPIRY = 365 * 24 * 60 * 60
SUCCESS_RESPONSE = { success: true }.to_json
ERROR_RESPONSE = { success: false }.to_json
NOT_AUTHED_RESPONSE = { error: 'not authenticated' }.to_json
NOT_TRACKING_RESPONSE = { error: 'not tracking user changes' }.to_json
INVALID_TRACK_RESPONSE = { error: 'invalid track' }.to_json
INVALID_RATING_RESPONSE = { error: 'invalid rating' }.to_json
TRACK_FIELD_MISSING_RESPONSE = { error: 'name/year/artist/genre cannot be empty' }.to_json
INVALID_YEAR_RESPONSE = { error: 'invalid year' }.to_json

GENRE_SQL = 'SELECT id, name FROM genres;'
GENRE_INT_INDICES = [0]
ARTIST_SQL = 'SELECT id, name, sort_name FROM artists;'
ARTIST_INT_INDICES = [0]
ALBUM_SQL = 'SELECT id, name, sort_name FROM albums;'
ALBUM_INT_INDICES = [0]
TRACK_SQL = 'SELECT id, name, sort_name, artist_id, album_artist_id, album_id, genre_id, ' +
  'year, duration, start, finish, track, disc, play_count, rating, ext FROM tracks;'
TRACK_INT_INDICES = [3, 4, 5, 6, 7, 11, 12, 13, 14]
PLAYLIST_SQL = 'SELECT id, name, parent_id, is_library FROM playlists;'
PLAYLIST_INT_INDICES = [3]
PLAYLIST_TRACK_SQL = 'SELECT playlist_id, string_agg(track_id, \',\') FROM playlist_tracks GROUP BY playlist_id;'

TRACK_INFO_SQL = 'SELECT name, file, ext FROM tracks WHERE id=$1;'
TRACK_EXISTS_SQL = 'SELECT COUNT(*) FROM tracks WHERE id=$1;'

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
  'wav' => 'audio/wav'
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
    set :bind, '/tmp/itunes-streamer.sock'
  else
    set :environment, :development
    set :port, 5567
  end

  def db
    if Config.use_persistent_db?
      @@db ||= PG.connect(user: Config['database_username'], dbname: Config['database_name'])
    else
      @db ||= PG.connect(user: Config['database_username'], dbname: Config['database_name'])
    end
  end

  def valid_username_and_password?(username, password)
    Config.vals['users'].has_key?(username) && Config.vals['users'][username]['password'] == password
  end

  def get_validated_username
    auth_header = request.env['HTTP_AUTHORIZATION']
    return nil if auth_header.nil? || !auth_header.start_with?('Bearer ')

    token = auth_header.gsub('Bearer ', '')
    begin
      payload, header = JWT.decode(token, Config['secret'], true, { algorithm: JWT_ALGO } )
    rescue
      return nil
    end

    exp = header["exp"]
    return nil if exp.nil? || Time.now > Time.at(exp.to_i)

    username = payload['username']
    return nil unless Config.vals['users'].has_key?(username)
    username
  end

  def is_authed?
    !get_validated_username.nil?
  end

  def track_user_changes?(username)
    Config.vals['users'].has_key?(username) && Config.vals['users'][username]['track_updates']
  end

  def track_exists?(track_id)
    result = db.exec_params(TRACK_EXISTS_SQL, [track_id])
    count = result.num_tuples > 0 ? result.getvalue(0, 0).to_i : 0
    count > 0
  end

  def send_track_if_exists(db, music_path, persistent_track_id, download)
    name, file, ext = db.exec_params(TRACK_INFO_SQL, [persistent_track_id]).values.first
    if file == nil || !MIME_TYPES.has_key?(ext)
      false
    else
      headers['Content-Disposition'] = "attachment; filename=\"#{name}.#{ext}\"" if download
      if Config.remote?
        headers['X-Accel-Redirect'] = Rack::Utils.escape_path("/music/#{file}")
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
    elsif !send_track_if_exists(db, Config['music_path'], params['splat'][0], false)
      raise Sinatra::NotFound
    end
  end

  get '/download/*' do
    if !is_authed?
      redirect to('/')
    elsif !send_track_if_exists(db, Config['music_path'], params['splat'][0], true)
      raise Sinatra::NotFound
    end
  end

  namespace '/api' do
    post '/auth' do
      if valid_username_and_password?(params[:username], params[:password])
        headers = { exp: Time.now.to_i + JWT_EXPIRY }
        token = JWT.encode({username: params[:username]}, Config['secret'], JWT_ALGO, headers)
        { token: token }.to_json
      else
        { token: nil }.to_json
      end
    end

    get '/heartbeat' do
      { is_authed: is_authed? }.to_json
    end

    get '/data' do
      username = get_validated_username
      if !username.nil?
        playlist_tracks = db.exec(PLAYLIST_TRACK_SQL).values
        playlist_tracks.each { |pt| pt[1] = pt[1].split(',') }

        { genres: convert_cols_to_ints(db.exec(GENRE_SQL).values, GENRE_INT_INDICES),
          artists: convert_cols_to_ints(db.exec(ARTIST_SQL).values, ARTIST_INT_INDICES),
          albums: convert_cols_to_ints(db.exec(ALBUM_SQL).values, ALBUM_INT_INDICES),
          tracks: convert_cols_to_ints(db.exec(TRACK_SQL).values, TRACK_INT_INDICES),
          playlists: convert_cols_to_ints(db.exec(PLAYLIST_SQL).values, PLAYLIST_INT_INDICES),
          playlist_tracks: playlist_tracks,
          track_user_changes: track_user_changes?(username) }.to_json
      else
        NOT_AUTHED_RESPONSE
      end
    end

    get '/updates' do
      if is_authed?
        { plays: db.exec(Export::Database::GET_PLAYS_SQL).values.flatten,
          ratings: db.exec(Export::Database::GET_RATING_UPDATES_SQL).values,
          names: db.exec(Export::Database::GET_NAME_UPDATES_SQL).values,
          artists: db.exec(Export::Database::GET_ARTIST_UPDATES_SQL).values,
          albums: db.exec(Export::Database::GET_ALBUM_UPDATES_SQL).values,
          album_artists: db.exec(Export::Database::GET_ALBUM_ARTIST_UPDATES_SQL).values,
          genres: db.exec(Export::Database::GET_GENRE_UPDATES_SQL).values,
          years: db.exec(Export::Database::GET_YEAR_UPDATES_SQL).values,
          starts: db.exec(Export::Database::GET_START_UPDATES_SQL).values,
          finishes: db.exec(Export::Database::GET_FINISH_UPDATES_SQL).values }.to_json
      else
        NOT_AUTHED_RESPONSE
      end
    end

    def perform_updates_if_should_track_changes(track_id, &block)
      username = get_validated_username
      if username.nil?
        NOT_AUTHED_RESPONSE
      elsif !track_user_changes?(username)
        NOT_TRACKING_RESPONSE
      elsif !track_exists?(track_id)
        INVALID_TRACK_RESPONSE
      else
        block.call
        SUCCESS_RESPONSE
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
        return INVALID_RATING_RESPONSE
      end

      if rating < 0 || rating > 100
        INVALID_RATING_RESPONSE
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
        return TRACK_FIELD_MISSING_RESPONSE
      end

      if params.has_key?('year')
        begin
          Integer(params['year'])
        rescue
          return INVALID_YEAR_RESPONSE
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
