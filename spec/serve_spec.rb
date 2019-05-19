ENV['RACK_ENV'] = 'test'

require 'rspec'
require 'rack/test'
require 'yaml'

module Config
  module_function

  def [](key)
    return YAML.load(File.open('config.yaml'))['local']['database_username'] if key == 'database_username'
    return 'test_itunes_streamer' if key == 'database_name'
    return './spec/' if key == 'music_path'
    return 'YJ1xcuoBPTUYX_cUZzEB' if key == 'secret'
  end

  def remote?
    false
  end

  def use_persistent_db?
    false
  end

  def vals
    {
      'users' => {
        'test123' => { 'password' => 'test123',
                       'track_updates' => true },
        'notrack' => { 'password' => 'notrack',
                       'track_updates' => false }
      }
    }
  end
end

require_relative '../serve'
require_relative '../export/database'
require_relative '../export/track'
require_relative '../export/playlist'
module Export ; class Database
  attr_accessor :db
  def clear ; @genres.clear ; @artists.clear ; @albums.clear ; end
end ; end

describe 'iTunes Streamer' do
  include Rack::Test::Methods

  def app
    Serve
  end

  before :all do
    `echo "fake mp3 contents" > spec/__test.mp3`
    @database = Export::Database.new(Config['database_username'], Config['database_name'])
    @database.clean_and_rebuild
    @db = @database.db
  end

  after :all do
    `rm spec/__test.mp3`
  end

  before :each do
    @db.exec('DELETE FROM genres')
    @db.exec('DELETE FROM artists')
    @db.exec('DELETE FROM albums')
    @db.exec('DELETE FROM tracks')
    @db.exec('DELETE FROM playlists')
    @db.exec('DELETE FROM playlist_tracks')
    @db.exec('DELETE FROM plays')
    @db.exec('DELETE FROM rating_updates')
    @db.exec('DELETE FROM name_updates')
    @db.exec('DELETE FROM artist_updates')
    @db.exec('DELETE FROM album_updates')
    @db.exec('DELETE FROM album_artist_updates')
    @db.exec('DELETE FROM genre_updates')
    @db.exec('DELETE FROM year_updates')
    @db.exec('DELETE FROM start_updates')
    @db.exec('DELETE FROM finish_updates')
    @db.exec('DELETE FROM rating_updates')
    @db.exec('DELETE FROM users')

    @database.clear
    @database.create_track(Export::Track.new('21D8E2441A5E2204', 'test_title', '', 'test_artist', '', 'test_artist', '', 'test_album', '',
                                            'test_genre', 2018, 1.23, 0.1, 1.22, 1, 1, 5, 100, ':__test.mp3'))
    @database.create_playlist(Export::Playlist.new('BDDCB0E03D499D53', 'test_playlist', 'none', -1, 3, "5E3FA18D81E469D2\n21D8E2441A5E2204\nB7F8970B634DDEE3"))
  end

  def get_first_value(query)
    @db.exec(query).getvalue(0, 0)
  end

  def fake_auth(username)
    @db.exec_params('INSERT INTO users (username, token) VALUES ($1, $2)', [username, '123'])
    { 'rack.session' => { 'token' => '123' }}
  end

  describe '/' do
    it 'presents a login form' do
      get '/'

      expect(last_response.body).to include('form')
      expect(last_response.body).to include('action="/"')
      expect(last_response.body).to include('method="post"')
    end

    it 'logs you in and redirect' do
      post '/', { username: 'test123', password: 'test123' }
      follow_redirect!

      expect(last_request.url).to eq('http://example.org/play')
      expect(get_first_value('SELECT username FROM users')).to eq('test123')
    end

    it 'should reject an invalid username' do
      post '/', { username: 'invalid', password: 'test123' }
      expect { follow_redirect! }.to raise_error(Rack::Test::Error)
    end

    it 'should reject an invalid username' do
      post '/', { username: 'test', password: 'invalid' }
      expect { follow_redirect! }.to raise_error(Rack::Test::Error)
    end
  end

  describe '/play' do
    it 'should redirect away if not logged in' do
      get '/play'
      follow_redirect!
      expect(last_request.url).to eq('http://example.org/')
    end

    it 'should send the html file if logged in' do
      get '/play', {}, fake_auth('test123')
      expect(last_response.body).to include('streamer.js')
    end
  end

  describe '/data.json' do
    it 'should redirect away if not logged in' do
      get '/data.json'
      follow_redirect!
      expect(last_request.url).to eq('http://example.org/')
    end

    it 'should dump all genres, artists, albums and tracks' do
      get '/data.json', {}, fake_auth('test123')
      expect(last_response.body).to include('test_title')
      expect(last_response.body).to include('test_artist')
      expect(last_response.body).to include('test_album')
      expect(last_response.body).to include('test_genre')
      expect(last_response.body).to include('mp3')
      expect(last_response.body).to include('test_playlist')
      expect(last_response.body).to include('["5E3FA18D81E469D2","21D8E2441A5E2204","B7F8970B634DDEE3"]')
    end

    it 'should include whether to track changes or not' do
      get '/data.json', {}, fake_auth('test123')
      expect(last_response.body).to include('"track_user_changes":true')
    end

    it 'should include whether to track changes or not' do
      get '/data.json', {}, fake_auth('notrack')
      expect(last_response.body).to include('"track_user_changes":false')
    end
  end

  describe '/tracks/*' do
    it 'should redirect if not logged in' do
      get '/tracks/21D8E2441A5E2204'
      follow_redirect!
      expect(last_request.url).to eq('http://example.org/')
    end

    it 'should 404 if the track doesn\'t exist in the database' do
      get '/tracks/A2D9E2441A6E2204', {}, fake_auth('test123')
      expect(last_response.status).to eq(404)
    end

    it 'should send the contents of the file' do
      get '/tracks/21D8E2441A5E2204', {}, fake_auth('test123')
      expect(last_response.body).to eq("fake mp3 contents\n")
    end
  end

  describe '/download/*' do
    it 'should redirect if not logged in' do
      get '/download/21D8E2441A5E2204'
      follow_redirect!
      expect(last_request.url).to eq('http://example.org/')
    end

    it 'should 404 if the track doesn\'t exist in the database' do
      get '/download/A2D9E2441A6E2204', {}, fake_auth('test123')
      expect(last_response.status).to eq(404)
    end

    it 'should send the contents of the file with a header' do
      get '/download/21D8E2441A5E2204', {}, fake_auth('test123')
      expect(last_response.body).to eq("fake mp3 contents\n")
      expect(last_response.headers['Content-Disposition']).to include('attachment')
      expect(last_response.headers['Content-Disposition']).to include('filename="test_title.mp3"')
    end
  end

  describe 'updates.json' do
    it 'should include all plays' do
      @db.exec('INSERT INTO plays (track_id) VALUES ($1);', ['5E3FA18D81E469D2'])
      @db.exec('INSERT INTO plays (track_id) VALUES ($1);', ['21D8E2441A5E2204'])
      @db.exec('INSERT INTO plays (track_id) VALUES ($1);', ['5E3FA18D81E469D2'])

      get '/updates.json'
      expect(last_response.body).to eq('{"plays":["5E3FA18D81E469D2","21D8E2441A5E2204","5E3FA18D81E469D2"],"ratings":[],"names":[],"artists":[],"albums":[],"album_artists":[],"genres":[],"years":[],"starts":[],"finishes":[]}')
    end

    it 'should include all ratings' do
      @db.exec('INSERT INTO rating_updates (track_id, rating) VALUES ($1, $2);', ['5E3FA18D81E469D2', 100])
      @db.exec('INSERT INTO rating_updates (track_id, rating) VALUES ($1, $2);', ['21D8E2441A5E2204', 80])
      @db.exec('INSERT INTO rating_updates (track_id, rating) VALUES ($1, $2);', ['5E3FA18D81E469D2', 60])

      get '/updates.json'
      expect(last_response.body).to eq('{"plays":[],"ratings":[["5E3FA18D81E469D2","100"],["21D8E2441A5E2204","80"],["5E3FA18D81E469D2","60"]],"names":[],"artists":[],"albums":[],"album_artists":[],"genres":[],"years":[],"starts":[],"finishes":[]}')
    end

    it 'should include all names' do
      @db.exec('INSERT INTO name_updates (track_id, name) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'abc'])
      @db.exec('INSERT INTO name_updates (track_id, name) VALUES ($1, $2);', ['21D8E2441A5E2204', 'def'])
      @db.exec('INSERT INTO name_updates (track_id, name) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'ghi'])

      get '/updates.json'
      expect(last_response.body).to eq('{"plays":[],"ratings":[],"names":[["5E3FA18D81E469D2","abc"],["21D8E2441A5E2204","def"],["5E3FA18D81E469D2","ghi"]],"artists":[],"albums":[],"album_artists":[],"genres":[],"years":[],"starts":[],"finishes":[]}')
    end

    it 'should include all artists' do
      @db.exec('INSERT INTO artist_updates (track_id, artist) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'abc'])
      @db.exec('INSERT INTO artist_updates (track_id, artist) VALUES ($1, $2);', ['21D8E2441A5E2204', 'def'])
      @db.exec('INSERT INTO artist_updates (track_id, artist) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'ghi'])

      get '/updates.json'
      expect(last_response.body).to eq('{"plays":[],"ratings":[],"names":[],"artists":[["5E3FA18D81E469D2","abc"],["21D8E2441A5E2204","def"],["5E3FA18D81E469D2","ghi"]],"albums":[],"album_artists":[],"genres":[],"years":[],"starts":[],"finishes":[]}')
    end

    it 'should include all albums' do
      @db.exec('INSERT INTO album_updates (track_id, album) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'abc'])
      @db.exec('INSERT INTO album_updates (track_id, album) VALUES ($1, $2);', ['21D8E2441A5E2204', 'def'])
      @db.exec('INSERT INTO album_updates (track_id, album) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'ghi'])

      get '/updates.json'
      expect(last_response.body).to eq('{"plays":[],"ratings":[],"names":[],"artists":[],"albums":[["5E3FA18D81E469D2","abc"],["21D8E2441A5E2204","def"],["5E3FA18D81E469D2","ghi"]],"album_artists":[],"genres":[],"years":[],"starts":[],"finishes":[]}')
    end

    it 'should include all album artists' do
      @db.exec('INSERT INTO album_artist_updates (track_id, album_artist) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'abc'])
      @db.exec('INSERT INTO album_artist_updates (track_id, album_artist) VALUES ($1, $2);', ['21D8E2441A5E2204', 'def'])
      @db.exec('INSERT INTO album_artist_updates (track_id, album_artist) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'ghi'])

      get '/updates.json'
      expect(last_response.body).to eq('{"plays":[],"ratings":[],"names":[],"artists":[],"albums":[],"album_artists":[["5E3FA18D81E469D2","abc"],["21D8E2441A5E2204","def"],["5E3FA18D81E469D2","ghi"]],"genres":[],"years":[],"starts":[],"finishes":[]}')
    end

    it 'should include all genres' do
      @db.exec('INSERT INTO genre_updates (track_id, genre) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'abc'])
      @db.exec('INSERT INTO genre_updates (track_id, genre) VALUES ($1, $2);', ['21D8E2441A5E2204', 'def'])
      @db.exec('INSERT INTO genre_updates (track_id, genre) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'ghi'])

      get '/updates.json'
      expect(last_response.body).to eq('{"plays":[],"ratings":[],"names":[],"artists":[],"albums":[],"album_artists":[],"genres":[["5E3FA18D81E469D2","abc"],["21D8E2441A5E2204","def"],["5E3FA18D81E469D2","ghi"]],"years":[],"starts":[],"finishes":[]}')
    end

    it 'should include all years' do
      @db.exec('INSERT INTO year_updates (track_id, year) VALUES ($1, $2);', ['5E3FA18D81E469D2', 100])
      @db.exec('INSERT INTO year_updates (track_id, year) VALUES ($1, $2);', ['21D8E2441A5E2204', 200])
      @db.exec('INSERT INTO year_updates (track_id, year) VALUES ($1, $2);', ['5E3FA18D81E469D2', 300])

      get '/updates.json'
      expect(last_response.body).to eq('{"plays":[],"ratings":[],"names":[],"artists":[],"albums":[],"album_artists":[],"genres":[],"years":[["5E3FA18D81E469D2","100"],["21D8E2441A5E2204","200"],["5E3FA18D81E469D2","300"]],"starts":[],"finishes":[]}')
    end

    it 'should include all starts' do
      @db.exec('INSERT INTO start_updates (track_id, start) VALUES ($1, $2);', ['5E3FA18D81E469D2', 1.1])
      @db.exec('INSERT INTO start_updates (track_id, start) VALUES ($1, $2);', ['21D8E2441A5E2204', 1.2])
      @db.exec('INSERT INTO start_updates (track_id, start) VALUES ($1, $2);', ['5E3FA18D81E469D2', 1.3])

      get '/updates.json'
      expect(last_response.body).to eq('{"plays":[],"ratings":[],"names":[],"artists":[],"albums":[],"album_artists":[],"genres":[],"years":[],"starts":[["5E3FA18D81E469D2","1.1"],["21D8E2441A5E2204","1.2"],["5E3FA18D81E469D2","1.3"]],"finishes":[]}')
    end

    it 'should include all finishes' do
      @db.exec('INSERT INTO finish_updates (track_id, finish) VALUES ($1, $2);', ['5E3FA18D81E469D2', 1.1])
      @db.exec('INSERT INTO finish_updates (track_id, finish) VALUES ($1, $2);', ['21D8E2441A5E2204', 1.2])
      @db.exec('INSERT INTO finish_updates (track_id, finish) VALUES ($1, $2);', ['5E3FA18D81E469D2', 1.3])

      get '/updates.json'
      expect(last_response.body).to eq('{"plays":[],"ratings":[],"names":[],"artists":[],"albums":[],"album_artists":[],"genres":[],"years":[],"starts":[],"finishes":[["5E3FA18D81E469D2","1.1"],["21D8E2441A5E2204","1.2"],["5E3FA18D81E469D2","1.3"]]}')
    end
  end

  describe '/play/*' do
    it 'should redirect if not logged in' do
      post '/play/21D8E2441A5E2204'
      follow_redirect!
      expect(last_request.url).to eq('http://example.org/')
    end

    it 'should 404 if the track doesn\'t exist in the database' do
      post '/play/AAD9E2442A6E2205', {}, fake_auth('test123')
      expect(last_response.status).to eq(404)
    end

    it 'should create a play if tracking this user\'s changes is enabled' do
      expect(get_first_value('SELECT play_count FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('5')
      post '/play/21D8E2441A5E2204', {}, fake_auth('test123')
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM plays')).to eq('1')
      expect(get_first_value('SELECT track_id FROM plays')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT play_count FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('6')
    end

    it 'should not create a play if tracking this user\'s changes is disabled' do
      expect(get_first_value('SELECT play_count FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('5')
      post '/play/21D8E2441A5E2204', {}, fake_auth('notrack')
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM plays')).to eq('0')
      expect(get_first_value('SELECT play_count FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('5')
    end
  end

  describe '/rating/*' do
    it 'should redirect if not logged in' do
      post '/rating/21D8E2441A5E2204/', { rating: '80' }
      follow_redirect!
      expect(last_request.url).to eq('http://example.org/')
    end

    it 'should 404 if the track doesn\'t exist in the database' do
      post '/rating/AAD9E2442A6E2205', { rating: '80' }, fake_auth('test123')
      expect(last_response.status).to eq(404)
    end

    it 'should create a rating update if tracking this user\'s changes is enabled' do
      expect(get_first_value('SELECT rating FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('100')

      post '/rating/21D8E2441A5E2204', { rating: '80' }, fake_auth('test123')
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM rating_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM rating_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT rating FROM rating_updates')).to eq('80')
      expect(get_first_value('SELECT rating FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('80')

      post '/rating/21D8E2441A5E2204', { rating: '100' }, fake_auth('test123')
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM rating_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM rating_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT rating FROM rating_updates')).to eq('100')
      expect(get_first_value('SELECT rating FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('100')
    end

    it 'should not create a rating update if tracking this user\'s changes is disabled' do
      expect(get_first_value('SELECT rating FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('100')
      post '/rating/21D8E2441A5E2204', { rating: '80' }, fake_auth('notrack')
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM rating_updates')).to eq('0')
      expect(get_first_value('SELECT rating FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('100')
    end
  end

  describe '/track-info/*' do
    it 'should redirect if not logged in' do
      post '/track-info/21D8E2441A5E2204', { name: 'abc' }
      follow_redirect!
      expect(last_request.url).to eq('http://example.org/')
    end

    it 'should 404 if the track doesn\'t exist in the database' do
      post '/track-info/AAD9E2442A6E2205', { name: 'abc' }, fake_auth('test123')
      expect(last_response.status).to eq(404)
    end

    it 'should not create a name update if tracking this user\'s changes is disabled' do
      expect(get_first_value('SELECT name FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('test_title')
      post '/track-info/21D8E2441A5E2204', { name: 'abc' }, fake_auth('notrack')
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM name_updates')).to eq('0')
      expect(get_first_value('SELECT name FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('test_title')
    end

    it 'should create a name update if tracking this user\'s changes is enabled' do
      expect(get_first_value('SELECT name FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('test_title')

      post '/track-info/21D8E2441A5E2204', { name: 'abc' }, fake_auth('test123')
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM name_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM name_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT name FROM name_updates')).to eq('abc')
      expect(get_first_value('SELECT name FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('abc')

      post '/track-info/21D8E2441A5E2204', { name: 'test_title' }, fake_auth('test123')
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM name_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM name_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT name FROM name_updates')).to eq('test_title')
      expect(get_first_value('SELECT name FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('test_title')
    end

    it 'should create a year update if tracking this user\'s changes is enabled' do
      expect(get_first_value('SELECT year FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('2018')

      post '/track-info/21D8E2441A5E2204', { year: '1970' }, fake_auth('test123')
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM year_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM year_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT year FROM year_updates')).to eq('1970')
      expect(get_first_value('SELECT year FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('1970')

      post '/track-info/21D8E2441A5E2204', { year: '1990'}, fake_auth('test123')
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM year_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM year_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT year FROM year_updates')).to eq('1990')
      expect(get_first_value('SELECT year FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('1990')
    end

    it 'should create a start update if tracking this user\'s changes is enabled' do
      expect(get_first_value('SELECT start FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('0.1')

      post '/track-info/21D8E2441A5E2204', { start: '1.2' }, fake_auth('test123')
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM start_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM start_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT start FROM start_updates')).to eq('1.2')
      expect(get_first_value('SELECT start FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('1.2')

      post '/track-info/21D8E2441A5E2204', { start: '1.3'}, fake_auth('test123')
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM start_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM start_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT start FROM start_updates')).to eq('1.3')
      expect(get_first_value('SELECT start FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('1.3')
    end

    it 'should create a finish update if tracking this user\'s changes is enabled' do
      expect(get_first_value('SELECT finish FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('1.22')

      post '/track-info/21D8E2441A5E2204', { finish: '2.3' }, fake_auth('test123')
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM finish_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM finish_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT finish FROM finish_updates')).to eq('2.3')
      expect(get_first_value('SELECT finish FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('2.3')

      post '/track-info/21D8E2441A5E2204', { finish: '2.4'}, fake_auth('test123')
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM finish_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM finish_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT finish FROM finish_updates')).to eq('2.4')
      expect(get_first_value('SELECT finish FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('2.4')
    end

    it 'should create an artist update if tracking this user\'s changes is enabled' do
      expect(get_first_value('SELECT artists.name FROM tracks JOIN artists ON tracks.artist_id = artists.id WHERE tracks.id=\'21D8E2441A5E2204\'')).to eq('test_artist')
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('1')

      post '/track-info/21D8E2441A5E2204', { artist: 'new_artist' }, fake_auth('test123')
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM artist_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM artist_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT artist FROM artist_updates')).to eq('new_artist')
      expect(get_first_value('SELECT artists.name FROM tracks JOIN artists ON tracks.artist_id = artists.id WHERE tracks.id=\'21D8E2441A5E2204\'')).to eq('new_artist')
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('2')

      post '/track-info/21D8E2441A5E2204', { artist: 'test_artist'}, fake_auth('test123')
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM artist_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM artist_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT artist FROM artist_updates')).to eq('test_artist')
      expect(get_first_value('SELECT artists.name FROM tracks JOIN artists ON tracks.artist_id = artists.id WHERE tracks.id=\'21D8E2441A5E2204\'')).to eq('test_artist')
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('2')
    end

    it 'should create an genre update if tracking this user\'s changes is enabled' do
      expect(get_first_value('SELECT genres.name FROM tracks JOIN genres ON tracks.genre_id = genres.id WHERE tracks.id=\'21D8E2441A5E2204\'')).to eq('test_genre')
      expect(get_first_value('SELECT COUNT(*) FROM genres')).to eq('1')

      post '/track-info/21D8E2441A5E2204', { genre: 'new_genre' }, fake_auth('test123')
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM genre_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM genre_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT genre FROM genre_updates')).to eq('new_genre')
      expect(get_first_value('SELECT genres.name FROM tracks JOIN genres ON tracks.genre_id = genres.id WHERE tracks.id=\'21D8E2441A5E2204\'')).to eq('new_genre')
      expect(get_first_value('SELECT COUNT(*) FROM genres')).to eq('2')

      post '/track-info/21D8E2441A5E2204', { genre: 'test_genre'}, fake_auth('test123')
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM genre_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM genre_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT genre FROM genre_updates')).to eq('test_genre')
      expect(get_first_value('SELECT genres.name FROM tracks JOIN genres ON tracks.genre_id = genres.id WHERE tracks.id=\'21D8E2441A5E2204\'')).to eq('test_genre')
      expect(get_first_value('SELECT COUNT(*) FROM genres')).to eq('2')
    end

    it 'should create an album artist update if tracking this user\'s changes is enabled' do
      expect(get_first_value('SELECT artists.name FROM tracks JOIN artists ON tracks.album_artist_id = artists.id WHERE tracks.id=\'21D8E2441A5E2204\'')).to eq('test_artist')
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('1')

      post '/track-info/21D8E2441A5E2204', { album_artist: 'new_album_artist' }, fake_auth('test123')
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM album_artist_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_artist_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT album_artist FROM album_artist_updates')).to eq('new_album_artist')
      expect(get_first_value('SELECT artists.name FROM tracks JOIN artists ON tracks.album_artist_id = artists.id WHERE tracks.id=\'21D8E2441A5E2204\'')).to eq('new_album_artist')
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('2')

      post '/track-info/21D8E2441A5E2204', { album_artist: '' }, fake_auth('test123')
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM album_artist_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_artist_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT album_artist FROM album_artist_updates')).to eq('')
      expect(get_first_value('SELECT album_artist_id FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq(nil)
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('2')

      post '/track-info/21D8E2441A5E2204', { album_artist: 'test_artist'}, fake_auth('test123')
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM album_artist_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_artist_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT album_artist FROM album_artist_updates')).to eq('test_artist')
      expect(get_first_value('SELECT artists.name FROM tracks JOIN artists ON tracks.album_artist_id = artists.id WHERE tracks.id=\'21D8E2441A5E2204\'')).to eq('test_artist')
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('2')
    end

    it 'should create an album album update if tracking this user\'s changes is enabled' do
      expect(get_first_value('SELECT albums.name FROM tracks JOIN albums ON tracks.album_id = albums.id WHERE tracks.id=\'21D8E2441A5E2204\'')).to eq('test_album')
      expect(get_first_value('SELECT COUNT(*) FROM albums')).to eq('1')

      post '/track-info/21D8E2441A5E2204', { album: 'new_album' }, fake_auth('test123')
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM album_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT album FROM album_updates')).to eq('new_album')
      expect(get_first_value('SELECT albums.name FROM tracks JOIN albums ON tracks.album_id = albums.id WHERE tracks.id=\'21D8E2441A5E2204\'')).to eq('new_album')
      expect(get_first_value('SELECT COUNT(*) FROM albums')).to eq('2')

      post '/track-info/21D8E2441A5E2204', { album: '' }, fake_auth('test123')
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM album_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT album FROM album_updates')).to eq('')
      expect(get_first_value('SELECT album_id FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq(nil)
      expect(get_first_value('SELECT COUNT(*) FROM albums')).to eq('2')

      post '/track-info/21D8E2441A5E2204', { album: 'test_album'}, fake_auth('test123')
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM album_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT album FROM album_updates')).to eq('test_album')
      expect(get_first_value('SELECT albums.name FROM tracks JOIN albums ON tracks.album_id = albums.id WHERE tracks.id=\'21D8E2441A5E2204\'')).to eq('test_album')
      expect(get_first_value('SELECT COUNT(*) FROM albums')).to eq('2')
    end
  end
end
