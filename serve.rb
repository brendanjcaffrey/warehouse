require 'sqlite3'
require 'sinatra'
require 'sinatra/json'

configure do
  mime_type :css, 'text/css'
  mime_type :js, 'application/javascript'

  mime_type :mp3, 'audio/mpeg'
  mime_type :mp4, 'audio/mp4'
  mime_type :m4a, 'audio/mp4'
  mime_type :aif, 'audio/aif'
  mime_type :aiff, 'audio/aif'
  mime_type :wav, 'audio/wav'
end

database_name = Config['database_name']
music_path = Config['music_path']

if Config.remote?
  set :environment, :production
  set :bind, '0.0.0.0'
else
  set :environment, :development
end

db = SQLite3::Database.new(database_name)
GENRE_SQL = 'SELECT id, name FROM genres';
ARTIST_SQL = 'SELECT id, name, sort_name FROM artists';
ALBUM_SQL = 'SELECT id, artist_id, name, sort_name FROM albums';
TRACK_SQL = 'SELECT id, name, sort_name, artist_id, album_id, genre_id, duration, start, ' +
  'finish, track, track_count, disc, disc_count, play_count, ext FROM tracks'
ACCEPTABLE_EXTENSIONS = ['mp3', 'mp4', 'm4a', 'aiff', 'aif', 'wav']

if !File.exists?(database_name)
  puts 'Unable to find export database, please generate with `rake export` first'
  exit
end

get '/' do
  send_file 'serve/index.html'
end

get '/style.css' do
  send_file 'serve/style.css', type: :css
end

get '/models.js' do
  send_file 'serve/models.js', type: :js
end

get '/streamer.js' do
  send_file 'serve/streamer.js', type: :js
end

get '/jquery.hotkeys.js' do
  send_file 'serve/jquery.hotkeys.js', type: :js
end

get '/data.json' do
  json genres: db.execute(GENRE_SQL),
       artists: db.execute(ARTIST_SQL),
       albums: db.execute(ALBUM_SQL),
       tracks: db.execute(TRACK_SQL)
end

get '/tracks/*.*' do
  id, ext = params['splat']
  file, actual_ext = db.get_first_row('SELECT file, ext FROM tracks WHERE id=?', id)

  if file == nil || ext != actual_ext || ACCEPTABLE_EXTENSIONS.index(ext) == nil
    raise Sinatra::NotFound
  else
    send_file music_path + file, type: ext
  end
end

get '/plays.json' do
  json db.execute('SELECT * FROM plays').flatten
end

post '/play/*.*' do
  id, ext = params['splat']
  actual_ext = db.get_first_value('SELECT ext FROM tracks WHERE id=?', id)

  if ext != actual_ext || ACCEPTABLE_EXTENSIONS.index(ext) == nil
    puts 'hi'
    puts id, ext, actual_ext
    puts 'yo'
    raise Sinatra::NotFound
  else
    db.execute('INSERT INTO plays (track_id) VALUES (?)', id);
  end
end
