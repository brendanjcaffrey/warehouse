require 'sqlite3'
require 'sinatra'
require 'sinatra/json'

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
set :session_secret, SecureRandom.urlsafe_base64(15).tr('lIO0', 'sxyz')

if Config.remote?
  set :environment, :production
  set :bind, '0.0.0.0'
else
  set :environment, :development
end


if !File.exists?(Config['database_name'])
  puts 'Unable to find export database, please generate with `rake export` first'
  exit
end

db = SQLite3::Database.new(Config['database_name'])
LOG_IN_SQL = 'INSERT INTO users (token, username) VALUES (?, ?)'
LOGGED_IN_SQL = 'SELECT COUNT(*) FROM users WHERE token=?'
USERNAME_SQL = 'SELECT username FROM users WHERE token=?'

GENRE_SQL = 'SELECT id, name FROM genres';
ARTIST_SQL = 'SELECT id, name, sort_name FROM artists';
ALBUM_SQL = 'SELECT id, artist_id, name, sort_name FROM albums';
TRACK_SQL = 'SELECT id, name, sort_name, artist_id, album_id, genre_id, duration, start, ' +
  'finish, track, track_count, disc, disc_count, play_count, ext FROM tracks'

TRACK_INFO_SQL = 'SELECT name, file, ext FROM tracks WHERE id=?'
TRACK_EXT_SQL = 'SELECT ext FROM tracks WHERE id=?'
CREATE_PLAY_SQL = 'INSERT INTO plays (track_id) VALUES (?)'
PLAYS_SQL = 'SELECT * FROM plays'

ACCEPTABLE_EXTENSIONS = ['mp3', 'mp4', 'm4a', 'aiff', 'aif', 'wav']


def valid_user?(username, password)
  Config.vals['users'].has_key?(username) && Config.vals['users'][username]['password'] == password
end

def track_user_plays?(username)
  Config.vals['users'].has_key?(username) && Config.vals['users'][username]['track_plays']
end

def check_login(db)
  session[:token] && db.get_first_value(LOGGED_IN_SQL, session[:token]) > 0
end

get '/' do
  send_file 'serve/login.html'
end

post '/' do
  if valid_user?(params[:username], params[:password])
    token = SecureRandom.urlsafe_base64(15).tr('lIO0', 'sxyz')
    db.execute(LOG_IN_SQL, token, params[:username])

    session[:token] = token
    redirect to('/play')
  else
    send_file 'serve/login.html'
  end
end

get '/play' do
  if check_login(db)
    send_file 'serve/play.html'
  else
    redirect to('/')
  end
end

get '/data.json' do
  if check_login(db)
    json genres: db.execute(GENRE_SQL),
         artists: db.execute(ARTIST_SQL),
         albums: db.execute(ALBUM_SQL),
         tracks: db.execute(TRACK_SQL)
  else
    redirect to('/')
  end
end

def find_track(db, music_path, id, ext, download)
  name, file, actual_ext = db.get_first_row(TRACK_INFO_SQL, id)
  if file == nil || ext != actual_ext || ACCEPTABLE_EXTENSIONS.index(ext) == nil
    false
  else
    headers['Content-Disposition'] = "attachment; filename=\"#{name}.#{ext}\"" if download
    send_file(music_path + file, type: ext)
    true
  end
end

get '/tracks/*.*' do
  if !check_login(db)
    redirect to('/')
  elsif !find_track(db, Config['music_path'], params['splat'][0],
                    params['splat'][1], false)
    raise Sinatra::NotFound
  end
end

get '/download/*.*' do
  if !check_login(db)
    redirect to('/')
  elsif !find_track(db, Config['music_path'], params['splat'][0],
                    params['splat'][1], true)
    raise Sinatra::NotFound
  end
end

get '/plays.json' do
  json db.execute(PLAYS_SQL).flatten
end

post '/play/*.*' do
  if !check_login(db)
    redirect to('/')
  else
    id, ext = params['splat']
    actual_ext = db.get_first_value(TRACK_EXT_SQL, id)

    if ext != actual_ext || ACCEPTABLE_EXTENSIONS.index(ext) == nil
      raise Sinatra::NotFound
    else
      username = db.get_first_value(USERNAME_SQL, session[:token])
      db.execute(CREATE_PLAY_SQL, id) if track_user_plays?(username)
    end
  end
end
