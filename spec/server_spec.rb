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
    return '01c814ac4499d22193c43cd6d4c3af62cab90ec76ba14bccf896c7add0415db0' if key == 'secret'
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

require_relative '../server'
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
    Server
  end

  def default_host
    'localhost'
  end

  def get_first_value(query)
    @db.exec(query).getvalue(0, 0)
  end

  def get_auth_header(username = 'test123')
    headers = { exp: Time.now.to_i + 5 }
    token = JWT.encode({username: username}, Config['secret'], JWT_ALGO, headers)
    { 'HTTP_AUTHORIZATION' => "Bearer #{token}" }
  end

  def get_expired_auth_header(username = 'test123')
    headers = { exp: Time.now.to_i - 5 }
    token = JWT.encode({username: username}, Config['secret'], JWT_ALGO, headers)
    { 'HTTP_AUTHORIZATION' => "Bearer #{token}" }
  end

  def get_invalid_auth_header
    { 'HTTP_AUTHORIZATION' => "Bearer blah" }
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

    @database.clear
    @database.create_track(Export::Track.new('21D8E2441A5E2204', 'test_title', '', 'test_artist', '', 'test_artist', '', 'test_album', '',
                                            'test_genre', 2018, 1.23, 0.1, 1.22, 2, 1, 5, 100, ':__test.mp3'))
    @database.create_playlist(Export::Playlist.new('BDDCB0E03D499D53', 'test_playlist', 'none', -1, 3, "5E3FA18D81E469D2\n21D8E2441A5E2204\nB7F8970B634DDEE3"))
  end

  describe '/' do
    it 'sends index.html' do
      get '/'
      expect(last_response.body).to include('Music Streamer')
    end
  end

  describe '/tracks/*' do
    it 'should redirect if not logged in' do
      get '/tracks/21D8E2441A5E2204'
      follow_redirect!
      expect(last_request.url).to eq('http://localhost/')
    end

    it 'should 404 if the track doesn\'t exist in the database' do
      get '/tracks/A2D9E2441A6E2204', {}, get_auth_header
      expect(last_response.status).to eq(404)
    end

    it 'should send the contents of the file' do
      get '/tracks/21D8E2441A5E2204', {}, get_auth_header
      expect(last_response.body).to eq("fake mp3 contents\n")
    end
  end

  describe '/download/*' do
    it 'should redirect if not logged in' do
      get '/download/21D8E2441A5E2204'
      follow_redirect!
      expect(last_request.url).to eq('http://localhost/')
    end

    it 'should 404 if the track doesn\'t exist in the database' do
      get '/download/A2D9E2441A6E2204', {}, get_auth_header
      expect(last_response.status).to eq(404)
    end

    it 'should send the contents of the file with a header' do
      get '/download/21D8E2441A5E2204', {}, get_auth_header
      expect(last_response.body).to eq("fake mp3 contents\n")
      expect(last_response.headers['Content-Disposition']).to include('attachment')
      expect(last_response.headers['Content-Disposition']).to include('filename="test_title.mp3"')
    end
  end

  describe '/api/auth' do
    it 'logs you in and redirect' do
      post '/api/auth', { username: 'test123', password: 'test123' }
      expect(last_response.body).to include('token')
      payload, header = JWT.decode(JSON.parse(last_response.body)['token'], Config['secret'], true, { algorithm: JWT_ALGO} )
      expect(header['exp']).to be > Time.now.to_i
      expect(payload['username']).to eq('test123')
    end

    it 'should reject an invalid username' do
      post '/api/auth', { username: 'invalid', password: 'test123' }
      expect(JSON.parse(last_response.body)['token']).to be_nil
    end

    it 'should reject an invalid password' do
      post '/api/auth', { username: 'test', password: 'invalid' }
      expect(JSON.parse(last_response.body)['token']).to be_nil
    end
  end

  describe '/api/heartbeat' do
    it 'should return true if valid jwt' do
      get '/api/heartbeat', {}, get_auth_header
      expect(JSON.parse(last_response.body)['is_authed']).to be true
    end

    it 'should return false if expired jwt' do
      get '/api/heartbeat', {}, get_expired_auth_header
      expect(JSON.parse(last_response.body)['is_authed']).to be false
    end

    it 'should return false if invalid jwt' do
      get '/api/heartbeat', {}, get_invalid_auth_header
      expect(JSON.parse(last_response.body)['is_authed']).to be false
    end

    it 'should return false if no auth header' do
      get '/api/heartbeat'
      expect(JSON.parse(last_response.body)['is_authed']).to be false
    end
  end

  describe '/api/data' do
    it 'should return an error if no jwt' do
      get '/api/data'
      expect(JSON.parse(last_response.body)['error']).to eq('not authenticated')
    end

    it 'should return an error if invalid jwt' do
      get '/api/data', {}, get_invalid_auth_header
      expect(JSON.parse(last_response.body)['error']).to eq('not authenticated')
    end

    it 'should return an error if expired jwt' do
      get '/api/data', {}, get_expired_auth_header
      expect(JSON.parse(last_response.body)['error']).to eq('not authenticated')
    end

    it 'should dump all genres, artists, albums and tracks' do
      get '/api/data', {}, get_auth_header
      json = JSON.parse(last_response.body)

      genre_id = json['genres'][0][0]
      genre_name = json['genres'][0][1]
      expect(genre_name).to eq('test_genre')

      artist_id = json['artists'][0][0]
      artist_name = json['artists'][0][1]
      expect(artist_name).to eq('test_artist')

      album_id = json['albums'][0][0]
      album_name = json['albums'][0][1]
      expect(album_name).to eq('test_album')

      track_name = json['tracks'][0][1]
      track_artist_id = json['tracks'][0][3]
      track_album_id = json['tracks'][0][5]
      track_genre_id = json['tracks'][0][6]
      track_year = json['tracks'][0][7]
      track_duration = json['tracks'][0][8]
      track_start = json['tracks'][0][9]
      track_finish = json['tracks'][0][10]
      track_track = json['tracks'][0][11]
      track_disc = json['tracks'][0][12]
      track_play_count = json['tracks'][0][13]
      track_rating = json['tracks'][0][14]
      track_ext = json['tracks'][0][15]
      expect(track_name).to eq('test_title')
      expect(track_artist_id).to eq(artist_id)
      expect(track_album_id).to eq(album_id)
      expect(track_genre_id).to eq(genre_id)
      expect(track_year).to eq(2018)
      expect(track_duration).to eq("1.23")
      expect(track_start).to eq("0.1")
      expect(track_finish).to eq("1.22")
      expect(track_track).to eq(2)
      expect(track_disc).to eq(1)
      expect(track_play_count).to eq(5)
      expect(track_rating).to eq(100)
      expect(track_ext).to eq('mp3')

      playlist_id = json['playlists'][0][0]
      playlist_name = json['playlists'][0][1]
      expect(playlist_name).to eq('test_playlist')

      playlist_track_id = json['playlist_tracks'][0][0]
      playlist_tracks = json['playlist_tracks'][0][1]
      expect(playlist_track_id).to eq(playlist_id)
      expect(playlist_tracks).to eq(%w{5E3FA18D81E469D2 21D8E2441A5E2204 B7F8970B634DDEE3})
    end

    it 'should include whether to track changes or not' do
      get '/api/data', {}, get_auth_header('test123')
      json = JSON.parse(last_response.body)
      expect(json['track_user_changes']).to be true
    end

    it 'should include whether to track changes or not' do
      get '/api/data', {}, get_auth_header('notrack')
      json = JSON.parse(last_response.body)
      expect(json['track_user_changes']).to be false
    end
  end

  describe '/api/updates' do
    it 'should return an error if no jwt' do
      get '/api/updates'
      expect(JSON.parse(last_response.body)['error']).to eq('not authenticated')
    end

    it 'should return an error if invalid jwt' do
      get '/api/updates', {}, get_invalid_auth_header
      expect(JSON.parse(last_response.body)['error']).to eq('not authenticated')
    end

    it 'should return an error if expired jwt' do
      get '/api/updates', {}, get_expired_auth_header
      expect(JSON.parse(last_response.body)['error']).to eq('not authenticated')
    end

    it 'should include all plays' do
      @db.exec('INSERT INTO plays (track_id) VALUES ($1);', ['5E3FA18D81E469D2'])
      @db.exec('INSERT INTO plays (track_id) VALUES ($1);', ['21D8E2441A5E2204'])
      @db.exec('INSERT INTO plays (track_id) VALUES ($1);', ['5E3FA18D81E469D2'])

      get '/api/updates', {}, get_auth_header
      expect(last_response.body).to eq('{"plays":["5E3FA18D81E469D2","21D8E2441A5E2204","5E3FA18D81E469D2"],"ratings":[],"names":[],"artists":[],"albums":[],"album_artists":[],"genres":[],"years":[],"starts":[],"finishes":[]}')
    end

    it 'should include all ratings' do
      @db.exec('INSERT INTO rating_updates (track_id, rating) VALUES ($1, $2);', ['5E3FA18D81E469D2', 100])
      @db.exec('INSERT INTO rating_updates (track_id, rating) VALUES ($1, $2);', ['21D8E2441A5E2204', 80])
      @db.exec('INSERT INTO rating_updates (track_id, rating) VALUES ($1, $2);', ['5E3FA18D81E469D2', 60])

      get '/api/updates', {}, get_auth_header
      expect(last_response.body).to eq('{"plays":[],"ratings":[["5E3FA18D81E469D2","100"],["21D8E2441A5E2204","80"],["5E3FA18D81E469D2","60"]],"names":[],"artists":[],"albums":[],"album_artists":[],"genres":[],"years":[],"starts":[],"finishes":[]}')
    end

    it 'should include all names' do
      @db.exec('INSERT INTO name_updates (track_id, name) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'abc'])
      @db.exec('INSERT INTO name_updates (track_id, name) VALUES ($1, $2);', ['21D8E2441A5E2204', 'def'])
      @db.exec('INSERT INTO name_updates (track_id, name) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'ghi'])

      get '/api/updates', {}, get_auth_header
      expect(last_response.body).to eq('{"plays":[],"ratings":[],"names":[["5E3FA18D81E469D2","abc"],["21D8E2441A5E2204","def"],["5E3FA18D81E469D2","ghi"]],"artists":[],"albums":[],"album_artists":[],"genres":[],"years":[],"starts":[],"finishes":[]}')
    end

    it 'should include all artists' do
      @db.exec('INSERT INTO artist_updates (track_id, artist) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'abc'])
      @db.exec('INSERT INTO artist_updates (track_id, artist) VALUES ($1, $2);', ['21D8E2441A5E2204', 'def'])
      @db.exec('INSERT INTO artist_updates (track_id, artist) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'ghi'])

      get '/api/updates', {}, get_auth_header
      expect(last_response.body).to eq('{"plays":[],"ratings":[],"names":[],"artists":[["5E3FA18D81E469D2","abc"],["21D8E2441A5E2204","def"],["5E3FA18D81E469D2","ghi"]],"albums":[],"album_artists":[],"genres":[],"years":[],"starts":[],"finishes":[]}')
    end

    it 'should include all albums' do
      @db.exec('INSERT INTO album_updates (track_id, album) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'abc'])
      @db.exec('INSERT INTO album_updates (track_id, album) VALUES ($1, $2);', ['21D8E2441A5E2204', 'def'])
      @db.exec('INSERT INTO album_updates (track_id, album) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'ghi'])

      get '/api/updates', {}, get_auth_header
      expect(last_response.body).to eq('{"plays":[],"ratings":[],"names":[],"artists":[],"albums":[["5E3FA18D81E469D2","abc"],["21D8E2441A5E2204","def"],["5E3FA18D81E469D2","ghi"]],"album_artists":[],"genres":[],"years":[],"starts":[],"finishes":[]}')
    end

    it 'should include all album artists' do
      @db.exec('INSERT INTO album_artist_updates (track_id, album_artist) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'abc'])
      @db.exec('INSERT INTO album_artist_updates (track_id, album_artist) VALUES ($1, $2);', ['21D8E2441A5E2204', 'def'])
      @db.exec('INSERT INTO album_artist_updates (track_id, album_artist) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'ghi'])

      get '/api/updates', {}, get_auth_header
      expect(last_response.body).to eq('{"plays":[],"ratings":[],"names":[],"artists":[],"albums":[],"album_artists":[["5E3FA18D81E469D2","abc"],["21D8E2441A5E2204","def"],["5E3FA18D81E469D2","ghi"]],"genres":[],"years":[],"starts":[],"finishes":[]}')
    end

    it 'should include all genres' do
      @db.exec('INSERT INTO genre_updates (track_id, genre) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'abc'])
      @db.exec('INSERT INTO genre_updates (track_id, genre) VALUES ($1, $2);', ['21D8E2441A5E2204', 'def'])
      @db.exec('INSERT INTO genre_updates (track_id, genre) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'ghi'])

      get '/api/updates', {}, get_auth_header
      expect(last_response.body).to eq('{"plays":[],"ratings":[],"names":[],"artists":[],"albums":[],"album_artists":[],"genres":[["5E3FA18D81E469D2","abc"],["21D8E2441A5E2204","def"],["5E3FA18D81E469D2","ghi"]],"years":[],"starts":[],"finishes":[]}')
    end

    it 'should include all years' do
      @db.exec('INSERT INTO year_updates (track_id, year) VALUES ($1, $2);', ['5E3FA18D81E469D2', 100])
      @db.exec('INSERT INTO year_updates (track_id, year) VALUES ($1, $2);', ['21D8E2441A5E2204', 200])
      @db.exec('INSERT INTO year_updates (track_id, year) VALUES ($1, $2);', ['5E3FA18D81E469D2', 300])

      get '/api/updates', {}, get_auth_header
      expect(last_response.body).to eq('{"plays":[],"ratings":[],"names":[],"artists":[],"albums":[],"album_artists":[],"genres":[],"years":[["5E3FA18D81E469D2","100"],["21D8E2441A5E2204","200"],["5E3FA18D81E469D2","300"]],"starts":[],"finishes":[]}')
    end

    it 'should include all starts' do
      @db.exec('INSERT INTO start_updates (track_id, start) VALUES ($1, $2);', ['5E3FA18D81E469D2', 1.1])
      @db.exec('INSERT INTO start_updates (track_id, start) VALUES ($1, $2);', ['21D8E2441A5E2204', 1.2])
      @db.exec('INSERT INTO start_updates (track_id, start) VALUES ($1, $2);', ['5E3FA18D81E469D2', 1.3])

      get '/api/updates', {}, get_auth_header
      expect(last_response.body).to eq('{"plays":[],"ratings":[],"names":[],"artists":[],"albums":[],"album_artists":[],"genres":[],"years":[],"starts":[["5E3FA18D81E469D2","1.1"],["21D8E2441A5E2204","1.2"],["5E3FA18D81E469D2","1.3"]],"finishes":[]}')
    end

    it 'should include all finishes' do
      @db.exec('INSERT INTO finish_updates (track_id, finish) VALUES ($1, $2);', ['5E3FA18D81E469D2', 1.1])
      @db.exec('INSERT INTO finish_updates (track_id, finish) VALUES ($1, $2);', ['21D8E2441A5E2204', 1.2])
      @db.exec('INSERT INTO finish_updates (track_id, finish) VALUES ($1, $2);', ['5E3FA18D81E469D2', 1.3])

      get '/api/updates', {}, get_auth_header
      expect(last_response.body).to eq('{"plays":[],"ratings":[],"names":[],"artists":[],"albums":[],"album_artists":[],"genres":[],"years":[],"starts":[],"finishes":[["5E3FA18D81E469D2","1.1"],["21D8E2441A5E2204","1.2"],["5E3FA18D81E469D2","1.3"]]}')
    end
  end

  describe '/api/play/*' do
    it 'should return an error if no jwt' do
      post '/api/play/21D8E2441A5E2204'
      expect(JSON.parse(last_response.body)['error']).to eq('not authenticated')
    end

    it 'should return an error if invalid jwt' do
      post '/api/play/21D8E2441A5E2204', {}, get_invalid_auth_header
      expect(JSON.parse(last_response.body)['error']).to eq('not authenticated')
    end

    it 'should return an error if expired jwt' do
      post '/api/play/21D8E2441A5E2204', {}, get_expired_auth_header
      expect(JSON.parse(last_response.body)['error']).to eq('not authenticated')
    end

    it 'should return an error if not tracking the user\'s changes' do
      post '/api/play/21D8E2441A5E2204', {}, get_auth_header('notrack')
      expect(JSON.parse(last_response.body)['error']).to eq('not tracking user changes')
    end

    it 'should return an error if track doesn\'t exist' do
      post '/api/play/ABCD', {}, get_auth_header
      expect(JSON.parse(last_response.body)['error']).to eq('invalid track')
    end

    it 'should create a play if tracking this user\'s changes is enabled' do
      expect(get_first_value('SELECT play_count FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('5')
      post '/api/play/21D8E2441A5E2204', {}, get_auth_header
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM plays')).to eq('1')
      expect(get_first_value('SELECT track_id FROM plays')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT play_count FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('6')
    end
  end

  describe '/rating/*' do
    it 'should return an error if rating is missing' do
      post '/api/rating/21D8E2441A5E2204', {}, get_auth_header
      expect(JSON.parse(last_response.body)['error']).to eq('invalid rating')
    end

    it 'should return an error if rating is non-numeric' do
      post '/api/rating/21D8E2441A5E2204', { rating: 'abcd' }, get_auth_header
      expect(JSON.parse(last_response.body)['error']).to eq('invalid rating')
    end

    it 'should return an error if rating is empty' do
      post '/api/rating/21D8E2441A5E2204', { rating: '' }, get_auth_header
      expect(JSON.parse(last_response.body)['error']).to eq('invalid rating')
    end

    it 'should return an error if rating is too high' do
      post '/api/rating/21D8E2441A5E2204', { rating: '120' }, get_auth_header
      expect(JSON.parse(last_response.body)['error']).to eq('invalid rating')
    end

    it 'should return an error if rating is too low' do
      post '/api/rating/21D8E2441A5E2204', { rating: '-1' }, get_auth_header
      expect(JSON.parse(last_response.body)['error']).to eq('invalid rating')
    end

    it 'should return an error if no jwt' do
      post '/api/rating/21D8E2441A5E2204', { rating: '80' }
      expect(JSON.parse(last_response.body)['error']).to eq('not authenticated')
    end

    it 'should return an error if invalid jwt' do
      post '/api/rating/21D8E2441A5E2204', { rating: '80' }, get_invalid_auth_header
      expect(JSON.parse(last_response.body)['error']).to eq('not authenticated')
    end

    it 'should return an error if expired jwt' do
      post '/api/rating/21D8E2441A5E2204', { rating: '80' }, get_expired_auth_header
      expect(JSON.parse(last_response.body)['error']).to eq('not authenticated')
    end

    it 'should return an error if not tracking the user\'s changes' do
      post '/api/rating/21D8E2441A5E2204', { rating: '80' }, get_auth_header('notrack')
      expect(JSON.parse(last_response.body)['error']).to eq('not tracking user changes')
    end

    it 'should return an error if track doesn\'t exist' do
      post '/api/rating/ABCD', { rating: '80' }, get_auth_header
      expect(JSON.parse(last_response.body)['error']).to eq('invalid track')
    end

    it 'should create a rating update if tracking this user\'s changes is enabled' do
      expect(get_first_value('SELECT rating FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('100')

      post '/api/rating/21D8E2441A5E2204', { rating: '80' }, get_auth_header
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM rating_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM rating_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT rating FROM rating_updates')).to eq('80')
      expect(get_first_value('SELECT rating FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('80')

      post '/api/rating/21D8E2441A5E2204', { rating: '100' }, get_auth_header
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM rating_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM rating_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT rating FROM rating_updates')).to eq('100')
      expect(get_first_value('SELECT rating FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('100')
    end
  end

  describe '/api/track-info/*' do
    it 'should return an error if no jwt' do
      post '/api/track-info/21D8E2441A5E2204'
      expect(JSON.parse(last_response.body)['error']).to eq('not authenticated')
    end

    it 'should return an error if invalid jwt' do
      post '/api/track-info/21D8E2441A5E2204', {}, get_invalid_auth_header
      expect(JSON.parse(last_response.body)['error']).to eq('not authenticated')
    end

    it 'should return an error if expired jwt' do
      post '/api/track-info/21D8E2441A5E2204', {}, get_expired_auth_header
      expect(JSON.parse(last_response.body)['error']).to eq('not authenticated')
    end

    it 'should return an error if not tracking the user\'s changes' do
      post '/api/track-info/21D8E2441A5E2204', {}, get_auth_header('notrack')
      expect(JSON.parse(last_response.body)['error']).to eq('not tracking user changes')
    end

    it 'should return an error if track doesn\'t exist' do
      post '/api/track-info/ABCD', {}, get_auth_header
      expect(JSON.parse(last_response.body)['error']).to eq('invalid track')
    end

    it 'should return an error if name is empty' do
      post '/api/track-info/ABCD', { name: '' }, get_auth_header
      expect(JSON.parse(last_response.body)['error']).to eq('name/year/artist/genre cannot be empty')
    end

    it 'should return an error if year is empty' do
      post '/api/track-info/ABCD', { year: '' }, get_auth_header
      expect(JSON.parse(last_response.body)['error']).to eq('name/year/artist/genre cannot be empty')
    end

    it 'should return an error if artist is empty' do
      post '/api/track-info/ABCD', { artist: '' }, get_auth_header
      expect(JSON.parse(last_response.body)['error']).to eq('name/year/artist/genre cannot be empty')
    end

    it 'should return an error if genre is empty' do
      post '/api/track-info/ABCD', { genre: '' }, get_auth_header
      expect(JSON.parse(last_response.body)['error']).to eq('name/year/artist/genre cannot be empty')
    end

    it 'should return an error if year is non-numeric' do
      post '/api/track-info/ABCD', { year: 'abcd' }, get_auth_header
      expect(JSON.parse(last_response.body)['error']).to eq('invalid year')
    end

    it 'should create a name update if tracking this user\'s changes is enabled' do
      expect(get_first_value('SELECT name FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('test_title')

      post '/api/track-info/21D8E2441A5E2204', { name: 'abc' }, get_auth_header
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM name_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM name_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT name FROM name_updates')).to eq('abc')
      expect(get_first_value('SELECT name FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('abc')

      post '/api/track-info/21D8E2441A5E2204', { name: 'test_title' }, get_auth_header
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM name_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM name_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT name FROM name_updates')).to eq('test_title')
      expect(get_first_value('SELECT name FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('test_title')
    end

    it 'should create a year update if tracking this user\'s changes is enabled' do
      expect(get_first_value('SELECT year FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('2018')

      post '/api/track-info/21D8E2441A5E2204', { year: '1970' }, get_auth_header
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM year_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM year_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT year FROM year_updates')).to eq('1970')
      expect(get_first_value('SELECT year FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('1970')

      post '/api/track-info/21D8E2441A5E2204', { year: '1990'}, get_auth_header
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM year_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM year_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT year FROM year_updates')).to eq('1990')
      expect(get_first_value('SELECT year FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('1990')
    end

    it 'should create a start update if tracking this user\'s changes is enabled' do
      expect(get_first_value('SELECT start FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('0.1')

      post '/api/track-info/21D8E2441A5E2204', { start: '1.2' }, get_auth_header
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM start_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM start_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT start FROM start_updates')).to eq('1.2')
      expect(get_first_value('SELECT start FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('1.2')

      post '/api/track-info/21D8E2441A5E2204', { start: '1.3'}, get_auth_header
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM start_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM start_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT start FROM start_updates')).to eq('1.3')
      expect(get_first_value('SELECT start FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('1.3')
    end

    it 'should create a finish update if tracking this user\'s changes is enabled' do
      expect(get_first_value('SELECT finish FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('1.22')

      post '/api/track-info/21D8E2441A5E2204', { finish: '2.3' }, get_auth_header
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM finish_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM finish_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT finish FROM finish_updates')).to eq('2.3')
      expect(get_first_value('SELECT finish FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('2.3')

      post '/api/track-info/21D8E2441A5E2204', { finish: '2.4'}, get_auth_header
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM finish_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM finish_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT finish FROM finish_updates')).to eq('2.4')
      expect(get_first_value('SELECT finish FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('2.4')
    end

    it 'should create an artist update if tracking this user\'s changes is enabled' do
      expect(get_first_value('SELECT artists.name FROM tracks JOIN artists ON tracks.artist_id = artists.id WHERE tracks.id=\'21D8E2441A5E2204\'')).to eq('test_artist')
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('1')

      post '/api/track-info/21D8E2441A5E2204', { artist: 'new_artist' }, get_auth_header
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM artist_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM artist_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT artist FROM artist_updates')).to eq('new_artist')
      expect(get_first_value('SELECT artists.name FROM tracks JOIN artists ON tracks.artist_id = artists.id WHERE tracks.id=\'21D8E2441A5E2204\'')).to eq('new_artist')
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('2')

      post '/api/track-info/21D8E2441A5E2204', { artist: 'test_artist'}, get_auth_header
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

      post '/api/track-info/21D8E2441A5E2204', { genre: 'new_genre' }, get_auth_header
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM genre_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM genre_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT genre FROM genre_updates')).to eq('new_genre')
      expect(get_first_value('SELECT genres.name FROM tracks JOIN genres ON tracks.genre_id = genres.id WHERE tracks.id=\'21D8E2441A5E2204\'')).to eq('new_genre')
      expect(get_first_value('SELECT COUNT(*) FROM genres')).to eq('2')

      post '/api/track-info/21D8E2441A5E2204', { genre: 'test_genre'}, get_auth_header
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

      post '/api/track-info/21D8E2441A5E2204', { album_artist: 'new_album_artist' }, get_auth_header
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM album_artist_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_artist_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT album_artist FROM album_artist_updates')).to eq('new_album_artist')
      expect(get_first_value('SELECT artists.name FROM tracks JOIN artists ON tracks.album_artist_id = artists.id WHERE tracks.id=\'21D8E2441A5E2204\'')).to eq('new_album_artist')
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('2')

      post '/api/track-info/21D8E2441A5E2204', { album_artist: '' }, get_auth_header
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM album_artist_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_artist_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT album_artist FROM album_artist_updates')).to eq('')
      expect(get_first_value('SELECT album_artist_id FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq(nil)
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('2')

      post '/api/track-info/21D8E2441A5E2204', { album_artist: 'test_artist'}, get_auth_header
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

      post '/api/track-info/21D8E2441A5E2204', { album: 'new_album' }, get_auth_header
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM album_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT album FROM album_updates')).to eq('new_album')
      expect(get_first_value('SELECT albums.name FROM tracks JOIN albums ON tracks.album_id = albums.id WHERE tracks.id=\'21D8E2441A5E2204\'')).to eq('new_album')
      expect(get_first_value('SELECT COUNT(*) FROM albums')).to eq('2')

      post '/api/track-info/21D8E2441A5E2204', { album: '' }, get_auth_header
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM album_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT album FROM album_updates')).to eq('')
      expect(get_first_value('SELECT album_id FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq(nil)
      expect(get_first_value('SELECT COUNT(*) FROM albums')).to eq('2')

      post '/api/track-info/21D8E2441A5E2204', { album: 'test_album'}, get_auth_header
      expect(last_response.status).to eq(200)
      expect(get_first_value('SELECT COUNT(*) FROM album_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT album FROM album_updates')).to eq('test_album')
      expect(get_first_value('SELECT albums.name FROM tracks JOIN albums ON tracks.album_id = albums.id WHERE tracks.id=\'21D8E2441A5E2204\'')).to eq('test_album')
      expect(get_first_value('SELECT COUNT(*) FROM albums')).to eq('2')
    end
  end
end
