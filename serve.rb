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

get '/data.json' do
  json genres: db.execute(GENRE_SQL),
       artists: db.execute(ARTIST_SQL),
       albums: db.execute(ALBUM_SQL),
       tracks: db.execute(TRACK_SQL)
end

def find_track(db, music_path, id, ext, download)
  name, file, actual_ext = db.get_first_row('SELECT name, file, ext FROM tracks WHERE id=?', id)
  if file == nil || ext != actual_ext || ACCEPTABLE_EXTENSIONS.index(ext) == nil
    false
  else
    headers['Content-Disposition'] = "attachment; filename=\"#{name}.#{ext}\"" if download
    send_file(music_path + file, type: ext)
  end
end

get '/tracks/*.*' do
  find_track(db, music_path, params['splat'][0], params['splat'][1], false)
end

get '/download/*.*' do
  find_track(db, music_path, params['splat'][0], params['splat'][1], true)
end

get '/plays.json' do
  json db.execute('SELECT * FROM plays').flatten
end

post '/play/*.*' do
  id, ext = params['splat']
  actual_ext = db.get_first_value('SELECT ext FROM tracks WHERE id=?', id)

  if ext != actual_ext || ACCEPTABLE_EXTENSIONS.index(ext) == nil
    raise Sinatra::NotFound
  else
    db.execute('INSERT INTO plays (track_id) VALUES (?)', id);
  end
end
