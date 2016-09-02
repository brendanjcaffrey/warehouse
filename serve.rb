require 'pg'
require 'sinatra/base'
require 'sinatra/json'

LOG_IN_SQL = 'INSERT INTO users (token, username) VALUES ($1, $2);'
LOGGED_IN_SQL = 'SELECT COUNT(*) FROM users WHERE token=$1;'
USERNAME_SQL = 'SELECT username FROM users WHERE token=$1;'

GENRE_SQL = 'SELECT id, name FROM genres;'
GENRE_INT_INDICES = [0]
ARTIST_SQL = 'SELECT id, name, sort_name FROM artists;'
ARTIST_INT_INDICES = [0]
ALBUM_SQL = 'SELECT id, artist_id, name, sort_name FROM albums;'
ALBUM_INT_INDICES = [0, 1]
TRACK_SQL = 'SELECT id, name, sort_name, artist_id, album_id, genre_id, duration, start, ' +
  'finish, track, track_count, disc, disc_count, play_count, ext FROM tracks'
TRACK_INT_INDICES = [0, 3, 4, 5]
PLAYLIST_SQL = 'SELECT id, name, parent_id, is_library FROM playlists;'
PLAYLIST_INT_INDICES = [0, 2, 3]
PLAYLIST_TRACK_SQL = 'SELECT playlist_id, string_agg(CAST(track_id AS VARCHAR), \',\') FROM playlist_tracks GROUP BY playlist_id;'
PLAYLIST_TRACK_INT_INDICES = [0]

TRACK_INFO_SQL = 'SELECT name, file, ext FROM tracks WHERE id=$1;'
TRACK_EXT_SQL = 'SELECT ext FROM tracks WHERE id=$1;'
CREATE_PLAY_SQL = 'INSERT INTO plays (track_id) VALUES ($1);'
PLAYS_SQL = 'SELECT * FROM plays;'

ACCEPTABLE_EXTENSIONS = ['mp3', 'mp4', 'm4a', 'aiff', 'aif', 'wav']


class Serve < Sinatra::Base
  configure do
    mime_type :mp3, 'audio/mpeg'
    mime_type :mp4, 'audio/mp4'
    mime_type :m4a, 'audio/mp4'
    mime_type :aif, 'audio/aif'
    mime_type :aiff, 'audio/aif'
    mime_type :wav, 'audio/wav'
  end

  set :public_folder, Proc.new { File.join(root, "serve") }
  enable :sessions
  set :session_secret, Config['secret']

  if Config.remote?
    set :environment, :production
    set :bind, '0.0.0.0'
  else
    set :environment, :development
  end

  def db
    if Config.use_persistent_db?
      @@db ||= PG.connect(user: Config['database_username'], dbname: Config['database_name'])
    else
      @db ||= PG.connect(user: Config['database_username'], dbname: Config['database_name'])
    end
  end

  def valid_user?(username, password)
    Config.vals['users'].has_key?(username) && Config.vals['users'][username]['password'] == password
  end

  def track_user_plays?(username)
    Config.vals['users'].has_key?(username) && Config.vals['users'][username]['track_plays']
  end

  def check_login
    session[:token] && db.exec_params(LOGGED_IN_SQL, [session[:token]]).getvalue(0, 0).to_i > 0
  end

  get '/' do
    send_file 'serve/login.html'
  end

  post '/' do
    if valid_user?(params[:username], params[:password])
      token = SecureRandom.urlsafe_base64(15).tr('lIO0', 'sxyz')
      db.exec_params(LOG_IN_SQL, [token, params[:username]])

      session[:token] = token
      redirect to('/play')
    else
      send_file 'serve/login.html'
    end
  end

  get '/play' do
    if check_login
      send_file 'serve/play.html'
    else
      redirect to('/')
    end
  end

  get '/data.json' do
    if check_login
      playlist_tracks = db.exec(PLAYLIST_TRACK_SQL).values
      playlist_tracks.each { |pt| pt[1] = pt[1].split(',').map(&:to_i) }

      json genres: convert_cols_to_ints(db.exec(GENRE_SQL).values, GENRE_INT_INDICES),
           artists: convert_cols_to_ints(db.exec(ARTIST_SQL).values, ARTIST_INT_INDICES),
           albums: convert_cols_to_ints(db.exec(ALBUM_SQL).values, ALBUM_INT_INDICES),
           tracks: convert_cols_to_ints(db.exec(TRACK_SQL).values, TRACK_INT_INDICES),
           playlists: convert_cols_to_ints(db.exec(PLAYLIST_SQL).values, PLAYLIST_INT_INDICES),
           playlist_tracks: convert_cols_to_ints(playlist_tracks, PLAYLIST_TRACK_INT_INDICES)
    else
      redirect to('/')
    end
  end

  def convert_cols_to_ints(rows, indices)
    rows.each do |cols|
      indices.each { |idx| cols[idx] = cols[idx].to_i }
    end

    rows
  end

  def send_track_if_exists(db, music_path, id, download)
    name, file, ext = db.exec_params(TRACK_INFO_SQL, [id]).values.first
    if file == nil || ACCEPTABLE_EXTENSIONS.index(ext) == nil
      false
    else
      headers['Content-Disposition'] = "attachment; filename=\"#{name}.#{ext}\"" if download
      send_file(music_path + file, type: ext)
      true
    end
  end

  get '/tracks/*' do
    if !check_login
      redirect to('/')
    elsif !send_track_if_exists(db, Config['music_path'], params['splat'][0], false)
      raise Sinatra::NotFound
    end
  end

  get '/download/*' do
    if !check_login
      redirect to('/')
    elsif !send_track_if_exists(db, Config['music_path'], params['splat'][0], true)
      raise Sinatra::NotFound
    end
  end

  get '/plays.json' do
    json db.exec(PLAYS_SQL).values.flatten.map(&:to_i)
  end

  post '/play/*' do
    if !check_login
      redirect to('/')
    else
      id = params['splat'][0]
      result = db.exec_params(TRACK_EXT_SQL, [id])
      ext = result.num_tuples > 0 ? result.getvalue(0, 0) : nil

      if ACCEPTABLE_EXTENSIONS.index(ext) == nil
        raise Sinatra::NotFound
      else
        username = db.exec_params(USERNAME_SQL, [session[:token]]).getvalue(0, 0)
        db.exec_params(CREATE_PLAY_SQL, [id]) if track_user_plays?(username)
      end
    end
  end
end
