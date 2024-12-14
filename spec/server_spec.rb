ENV['RACK_ENV'] = 'test'

require 'rspec'
require 'rack/test'
require 'yaml'
require_relative '../shared/messages_pb'

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
    @database.create_playlist(Export::Playlist.new('BDDCB0E03D499D53', 'test_playlist', 'none', '', 3, "5E3FA18D81E469D2\n21D8E2441A5E2204\nB7F8970B634DDEE3"))
    @database.create_playlist(Export::Playlist.new('1111111111111111', 'library', 'Music', '', 100, ""))
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

  describe 'post /api/auth' do
    it 'return a token' do
      post '/api/auth', { username: 'test123', password: 'test123' }
      response = AuthAttemptResponse.decode(last_response.body)
      expect(response.response).to eq(:token)
      payload, header = JWT.decode(response.token, Config['secret'], true, { algorithm: JWT_ALGO} )
      expect(header['exp']).to be > Time.now.to_i
      expect(payload['username']).to eq('test123')
    end

    it 'should reject an invalid username' do
      post '/api/auth', { username: 'invalid', password: 'test123' }
      response = AuthAttemptResponse.decode(last_response.body)
      expect(response.response).to eq(:error)
    end

    it 'should reject an invalid password' do
      post '/api/auth', { username: 'test', password: 'invalid' }
      response = AuthAttemptResponse.decode(last_response.body)
      expect(response.response).to eq(:error)
    end
  end

  describe 'get /api/auth' do
    it 'should return true if valid jwt' do
      get '/api/auth', {}, get_auth_header
      expect(AuthQueryResponse.decode(last_response.body).isAuthed).to be true
    end

    it 'should return false if no auth header' do
      get '/api/auth'
      expect(AuthQueryResponse.decode(last_response.body).isAuthed).to be false
    end

    it 'should return false if expired jwt' do
      get '/api/auth', {}, get_expired_auth_header
      expect(AuthQueryResponse.decode(last_response.body).isAuthed).to be false
    end

    it 'should return false if invalid jwt' do
      get '/api/auth', {}, get_invalid_auth_header
      expect(AuthQueryResponse.decode(last_response.body).isAuthed).to be false
    end
  end

  describe 'get /api/library' do
    it 'should return an error if no jwt' do
      get '/api/library'
      expect(LibraryResponse.decode(last_response.body).response).to eq(:error)
    end

    it 'should return an error if invalid jwt' do
      get '/api/library', {}, get_invalid_auth_header
      expect(LibraryResponse.decode(last_response.body).response).to eq(:error)
    end

    it 'should return an error if expired jwt' do
      get '/api/library', {}, get_expired_auth_header
      expect(LibraryResponse.decode(last_response.body).response).to eq(:error)
    end

    it 'should dump all genres, artists, albums and tracks' do
      get '/api/library', {}, get_auth_header
      library = LibraryResponse.decode(last_response.body).library

      expect(library.genres.length).to eq(1)
      genre_id = library.genres.keys.first
      expect(library.genres[genre_id].name).to eq('test_genre')

      expect(library.artists.length).to eq(1)
      artist_id = library.artists.keys.first
      expect(library.artists[artist_id].name).to eq('test_artist')
      expect(library.artists[artist_id].sortName).to eq('')

      expect(library.albums.length).to eq(1)
      album_id = library.albums.keys.first
      expect(library.albums[album_id].name).to eq('test_album')
      expect(library.albums[album_id].sortName).to eq('')

      expect(library.tracks.length).to eq(1)
      track = library.tracks.first
      expect(track.id).to eq('21D8E2441A5E2204')
      expect(track.name).to eq('test_title')
      expect(track.sortName).to eq('')
      expect(track.artistId).to eq(artist_id)
      expect(track.albumId).to eq(album_id)
      expect(track.genreId).to eq(genre_id)
      expect(track.year).to eq(2018)
      expect(track.duration).to be_within(0.001).of(1.23)
      expect(track.start).to be_within(0.001).of(0.1)
      expect(track.finish).to be_within(0.001).of(1.22)
      expect(track.trackNumber).to eq(2)
      expect(track.discNumber).to eq(1)
      expect(track.playCount).to eq(5)
      expect(track.rating).to eq(100)
      expect(track.ext).to eq('mp3')

      expect(library.playlists.length).to eq(2)
      playlist = library.playlists.first
      expect(playlist.id).to eq('BDDCB0E03D499D53')
      expect(playlist.name).to eq('test_playlist')
      expect(playlist.parentId).to eq('')
      expect(playlist.isLibrary).to be(false)
      expect(playlist.trackIds).to eq(%w{5E3FA18D81E469D2 21D8E2441A5E2204 B7F8970B634DDEE3})

      playlist = library.playlists.last
      expect(playlist.id).to eq('1111111111111111')
      expect(playlist.name).to eq('library')
      expect(playlist.parentId).to eq('')
      expect(playlist.isLibrary).to be(true)
      expect(playlist.trackIds).to eq([])
    end

    it 'should include whether to track changes or not' do
      get '/api/library', {}, get_auth_header('test123')
      library = LibraryResponse.decode(last_response.body).library
      expect(library.trackUserChanges).to be true

      get '/api/library', {}, get_auth_header('notrack')
      library = LibraryResponse.decode(last_response.body).library
      expect(library.trackUserChanges).to be false
    end
  end

  describe '/api/updates' do
    it 'should return an error if no jwt' do
      get '/api/updates'
      expect(UpdatesResponse.decode(last_response.body).response).to eq(:error)
    end

    it 'should return an error if invalid jwt' do
      get '/api/updates', {}, get_invalid_auth_header
      expect(UpdatesResponse.decode(last_response.body).response).to eq(:error)
    end

    it 'should return an error if expired jwt' do
      get '/api/updates', {}, get_expired_auth_header
      expect(UpdatesResponse.decode(last_response.body).response).to eq(:error)
    end

    it 'should include all plays' do
      @db.exec('INSERT INTO plays (track_id) VALUES ($1);', ['5E3FA18D81E469D2'])
      @db.exec('INSERT INTO plays (track_id) VALUES ($1);', ['21D8E2441A5E2204'])
      @db.exec('INSERT INTO plays (track_id) VALUES ($1);', ['5E3FA18D81E469D2'])

      get '/api/updates', {}, get_auth_header
      updates = UpdatesResponse.decode(last_response.body).updates
      expect(updates.plays.map(&:trackId)).to eq(%w{5E3FA18D81E469D2 21D8E2441A5E2204 5E3FA18D81E469D2})
    end

    it 'should include all ratings' do
      @db.exec('INSERT INTO rating_updates (track_id, rating) VALUES ($1, $2);', ['5E3FA18D81E469D2', 100])
      @db.exec('INSERT INTO rating_updates (track_id, rating) VALUES ($1, $2);', ['21D8E2441A5E2204', 80])
      @db.exec('INSERT INTO rating_updates (track_id, rating) VALUES ($1, $2);', ['5E3FA18D81E469D2', 60])

      get '/api/updates', {}, get_auth_header
      ratings = UpdatesResponse.decode(last_response.body).updates.ratings
      expect(ratings.map(&:trackId)).to eq(%w{5E3FA18D81E469D2 21D8E2441A5E2204 5E3FA18D81E469D2})
      expect(ratings.map(&:value)).to eq([100, 80, 60])
    end

    it 'should include all names' do
      @db.exec('INSERT INTO name_updates (track_id, name) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'abc'])
      @db.exec('INSERT INTO name_updates (track_id, name) VALUES ($1, $2);', ['21D8E2441A5E2204', 'def'])
      @db.exec('INSERT INTO name_updates (track_id, name) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'ghi'])

      get '/api/updates', {}, get_auth_header
      names = UpdatesResponse.decode(last_response.body).updates.names
      expect(names.map(&:trackId)).to eq(%w{5E3FA18D81E469D2 21D8E2441A5E2204 5E3FA18D81E469D2})
      expect(names.map(&:value)).to eq(%w{abc def ghi})
    end

    it 'should include all artists' do
      @db.exec('INSERT INTO artist_updates (track_id, artist) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'abc'])
      @db.exec('INSERT INTO artist_updates (track_id, artist) VALUES ($1, $2);', ['21D8E2441A5E2204', 'def'])
      @db.exec('INSERT INTO artist_updates (track_id, artist) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'ghi'])

      get '/api/updates', {}, get_auth_header
      artists = UpdatesResponse.decode(last_response.body).updates.artists
      expect(artists.map(&:trackId)).to eq(%w{5E3FA18D81E469D2 21D8E2441A5E2204 5E3FA18D81E469D2})
      expect(artists.map(&:value)).to eq(%w{abc def ghi})
    end

    it 'should include all albums' do
      @db.exec('INSERT INTO album_updates (track_id, album) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'abc'])
      @db.exec('INSERT INTO album_updates (track_id, album) VALUES ($1, $2);', ['21D8E2441A5E2204', 'def'])
      @db.exec('INSERT INTO album_updates (track_id, album) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'ghi'])

      get '/api/updates', {}, get_auth_header
      albums = UpdatesResponse.decode(last_response.body).updates.albums
      expect(albums.map(&:trackId)).to eq(%w{5E3FA18D81E469D2 21D8E2441A5E2204 5E3FA18D81E469D2})
      expect(albums.map(&:value)).to eq(%w{abc def ghi})
    end

    it 'should include all album artists' do
      @db.exec('INSERT INTO album_artist_updates (track_id, album_artist) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'abc'])
      @db.exec('INSERT INTO album_artist_updates (track_id, album_artist) VALUES ($1, $2);', ['21D8E2441A5E2204', 'def'])
      @db.exec('INSERT INTO album_artist_updates (track_id, album_artist) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'ghi'])

      get '/api/updates', {}, get_auth_header
      album_artists = UpdatesResponse.decode(last_response.body).updates.albumArtists
      expect(album_artists.map(&:trackId)).to eq(%w{5E3FA18D81E469D2 21D8E2441A5E2204 5E3FA18D81E469D2})
      expect(album_artists.map(&:value)).to eq(%w{abc def ghi})
    end

    it 'should include all genres' do
      @db.exec('INSERT INTO genre_updates (track_id, genre) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'abc'])
      @db.exec('INSERT INTO genre_updates (track_id, genre) VALUES ($1, $2);', ['21D8E2441A5E2204', 'def'])
      @db.exec('INSERT INTO genre_updates (track_id, genre) VALUES ($1, $2);', ['5E3FA18D81E469D2', 'ghi'])

      get '/api/updates', {}, get_auth_header
      genres = UpdatesResponse.decode(last_response.body).updates.genres
      expect(genres.map(&:trackId)).to eq(%w{5E3FA18D81E469D2 21D8E2441A5E2204 5E3FA18D81E469D2})
      expect(genres.map(&:value)).to eq(%w{abc def ghi})
    end

    it 'should include all years' do
      @db.exec('INSERT INTO year_updates (track_id, year) VALUES ($1, $2);', ['5E3FA18D81E469D2', 100])
      @db.exec('INSERT INTO year_updates (track_id, year) VALUES ($1, $2);', ['21D8E2441A5E2204', 200])
      @db.exec('INSERT INTO year_updates (track_id, year) VALUES ($1, $2);', ['5E3FA18D81E469D2', 300])

      get '/api/updates', {}, get_auth_header
      years = UpdatesResponse.decode(last_response.body).updates.years
      expect(years.map(&:trackId)).to eq(%w{5E3FA18D81E469D2 21D8E2441A5E2204 5E3FA18D81E469D2})
      expect(years.map(&:value)).to eq([100, 200, 300])
    end

    it 'should include all starts' do
      @db.exec('INSERT INTO start_updates (track_id, start) VALUES ($1, $2);', ['5E3FA18D81E469D2', 1.1])
      @db.exec('INSERT INTO start_updates (track_id, start) VALUES ($1, $2);', ['21D8E2441A5E2204', 1.2])
      @db.exec('INSERT INTO start_updates (track_id, start) VALUES ($1, $2);', ['5E3FA18D81E469D2', 1.3])

      get '/api/updates', {}, get_auth_header
      starts = UpdatesResponse.decode(last_response.body).updates.starts
      expect(starts.map(&:trackId)).to eq(%w{5E3FA18D81E469D2 21D8E2441A5E2204 5E3FA18D81E469D2})
      expect(starts[0].value).to be_within(0.001).of(1.1)
      expect(starts[1].value).to be_within(0.001).of(1.2)
      expect(starts[2].value).to be_within(0.001).of(1.3)
    end

    it 'should include all finishes' do
      @db.exec('INSERT INTO finish_updates (track_id, finish) VALUES ($1, $2);', ['5E3FA18D81E469D2', 1.1])
      @db.exec('INSERT INTO finish_updates (track_id, finish) VALUES ($1, $2);', ['21D8E2441A5E2204', 1.2])
      @db.exec('INSERT INTO finish_updates (track_id, finish) VALUES ($1, $2);', ['5E3FA18D81E469D2', 1.3])

      get '/api/updates', {}, get_auth_header
      finishes = UpdatesResponse.decode(last_response.body).updates.finishes
      expect(finishes.map(&:trackId)).to eq(%w{5E3FA18D81E469D2 21D8E2441A5E2204 5E3FA18D81E469D2})
      expect(finishes[0].value).to be_within(0.001).of(1.1)
      expect(finishes[1].value).to be_within(0.001).of(1.2)
      expect(finishes[2].value).to be_within(0.001).of(1.3)
    end
  end

  describe '/api/play/*' do
    it 'should return an error if no jwt' do
      post '/api/play/21D8E2441A5E2204'
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'should return an error if invalid jwt' do
      post '/api/play/21D8E2441A5E2204', {}, get_invalid_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'should return an error if expired jwt' do
      post '/api/play/21D8E2441A5E2204', {}, get_expired_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'should return an error if not tracking the user\'s changes' do
      post '/api/play/21D8E2441A5E2204', {}, get_auth_header('notrack')
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_TRACKING_ERROR)
    end

    it 'should return an error if track doesn\'t exist' do
      post '/api/play/ABCD', {}, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_TRACK_ERROR)
    end

    it 'should create a play if tracking this user\'s changes is enabled' do
      expect(get_first_value('SELECT play_count FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('5')
      post '/api/play/21D8E2441A5E2204', {}, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM plays')).to eq('1')
      expect(get_first_value('SELECT track_id FROM plays')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT play_count FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('6')
    end
  end

  describe '/rating/*' do
    it 'should return an error if rating is missing' do
      post '/api/rating/21D8E2441A5E2204', {}, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_RATING_ERROR)
    end

    it 'should return an error if rating is non-numeric' do
      post '/api/rating/21D8E2441A5E2204', { rating: 'abcd' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_RATING_ERROR)
    end

    it 'should return an error if rating is empty' do
      post '/api/rating/21D8E2441A5E2204', { rating: '' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_RATING_ERROR)
    end

    it 'should return an error if rating is too high' do
      post '/api/rating/21D8E2441A5E2204', { rating: '120' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_RATING_ERROR)
    end

    it 'should return an error if rating is too low' do
      post '/api/rating/21D8E2441A5E2204', { rating: '-1' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_RATING_ERROR)
    end

    it 'should return an error if no jwt' do
      post '/api/rating/21D8E2441A5E2204', { rating: '80' }
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'should return an error if invalid jwt' do
      post '/api/rating/21D8E2441A5E2204', { rating: '80' }, get_invalid_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'should return an error if expired jwt' do
      post '/api/rating/21D8E2441A5E2204', { rating: '80' }, get_expired_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'should return an error if not tracking the user\'s changes' do
      post '/api/rating/21D8E2441A5E2204', { rating: '80' }, get_auth_header('notrack')
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_TRACKING_ERROR)
    end

    it 'should return an error if track doesn\'t exist' do
      post '/api/rating/ABCD', { rating: '80' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_TRACK_ERROR)
    end

    it 'should create a rating update if tracking this user\'s changes is enabled' do
      expect(get_first_value('SELECT rating FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('100')

      post '/api/rating/21D8E2441A5E2204', { rating: '80' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM rating_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM rating_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT rating FROM rating_updates')).to eq('80')
      expect(get_first_value('SELECT rating FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('80')

      post '/api/rating/21D8E2441A5E2204', { rating: '100' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM rating_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM rating_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT rating FROM rating_updates')).to eq('100')
      expect(get_first_value('SELECT rating FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('100')
    end
  end

  describe '/api/track-info/*' do
    it 'should return an error if no jwt' do
      post '/api/track-info/21D8E2441A5E2204'
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'should return an error if invalid jwt' do
      post '/api/track-info/21D8E2441A5E2204', {}, get_invalid_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'should return an error if expired jwt' do
      post '/api/track-info/21D8E2441A5E2204', {}, get_expired_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'should return an error if not tracking the user\'s changes' do
      post '/api/track-info/21D8E2441A5E2204', {}, get_auth_header('notrack')
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_TRACKING_ERROR)
    end

    it 'should return an error if track doesn\'t exist' do
      post '/api/track-info/ABCD', {}, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_TRACK_ERROR)
    end

    it 'should return an error if name is empty' do
      post '/api/track-info/ABCD', { name: '' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(TRACK_FIELD_MISSING_ERROR)
    end

    it 'should return an error if year is empty' do
      post '/api/track-info/ABCD', { year: '' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(TRACK_FIELD_MISSING_ERROR)
    end

    it 'should return an error if artist is empty' do
      post '/api/track-info/ABCD', { artist: '' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(TRACK_FIELD_MISSING_ERROR)
    end

    it 'should return an error if genre is empty' do
      post '/api/track-info/ABCD', { genre: '' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(TRACK_FIELD_MISSING_ERROR)
    end

    it 'should return an error if year is non-numeric' do
      post '/api/track-info/ABCD', { year: 'abcd' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_YEAR_ERROR)
    end

    it 'should create a name update if tracking this user\'s changes is enabled' do
      expect(get_first_value('SELECT name FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('test_title')

      post '/api/track-info/21D8E2441A5E2204', { name: 'abc' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM name_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM name_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT name FROM name_updates')).to eq('abc')
      expect(get_first_value('SELECT name FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('abc')

      post '/api/track-info/21D8E2441A5E2204', { name: 'test_title' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM name_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM name_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT name FROM name_updates')).to eq('test_title')
      expect(get_first_value('SELECT name FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('test_title')
    end

    it 'should create a year update if tracking this user\'s changes is enabled' do
      expect(get_first_value('SELECT year FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('2018')

      post '/api/track-info/21D8E2441A5E2204', { year: '1970' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM year_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM year_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT year FROM year_updates')).to eq('1970')
      expect(get_first_value('SELECT year FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('1970')

      post '/api/track-info/21D8E2441A5E2204', { year: '1990'}, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM year_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM year_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT year FROM year_updates')).to eq('1990')
      expect(get_first_value('SELECT year FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('1990')
    end

    it 'should create a start update if tracking this user\'s changes is enabled' do
      expect(get_first_value('SELECT start FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('0.1')

      post '/api/track-info/21D8E2441A5E2204', { start: '1.2' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM start_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM start_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT start FROM start_updates')).to eq('1.2')
      expect(get_first_value('SELECT start FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('1.2')

      post '/api/track-info/21D8E2441A5E2204', { start: '1.3'}, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM start_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM start_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT start FROM start_updates')).to eq('1.3')
      expect(get_first_value('SELECT start FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('1.3')
    end

    it 'should create a finish update if tracking this user\'s changes is enabled' do
      expect(get_first_value('SELECT finish FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('1.22')

      post '/api/track-info/21D8E2441A5E2204', { finish: '2.3' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM finish_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM finish_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT finish FROM finish_updates')).to eq('2.3')
      expect(get_first_value('SELECT finish FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('2.3')

      post '/api/track-info/21D8E2441A5E2204', { finish: '2.4'}, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM finish_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM finish_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT finish FROM finish_updates')).to eq('2.4')
      expect(get_first_value('SELECT finish FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq('2.4')
    end

    it 'should create an artist update if tracking this user\'s changes is enabled' do
      expect(get_first_value('SELECT artists.name FROM tracks JOIN artists ON tracks.artist_id = artists.id WHERE tracks.id=\'21D8E2441A5E2204\'')).to eq('test_artist')
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('1')

      post '/api/track-info/21D8E2441A5E2204', { artist: 'new_artist' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM artist_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM artist_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT artist FROM artist_updates')).to eq('new_artist')
      expect(get_first_value('SELECT artists.name FROM tracks JOIN artists ON tracks.artist_id = artists.id WHERE tracks.id=\'21D8E2441A5E2204\'')).to eq('new_artist')
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('2')

      post '/api/track-info/21D8E2441A5E2204', { artist: 'test_artist'}, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
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
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM genre_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM genre_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT genre FROM genre_updates')).to eq('new_genre')
      expect(get_first_value('SELECT genres.name FROM tracks JOIN genres ON tracks.genre_id = genres.id WHERE tracks.id=\'21D8E2441A5E2204\'')).to eq('new_genre')
      expect(get_first_value('SELECT COUNT(*) FROM genres')).to eq('2')

      post '/api/track-info/21D8E2441A5E2204', { genre: 'test_genre'}, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
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
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM album_artist_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_artist_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT album_artist FROM album_artist_updates')).to eq('new_album_artist')
      expect(get_first_value('SELECT artists.name FROM tracks JOIN artists ON tracks.album_artist_id = artists.id WHERE tracks.id=\'21D8E2441A5E2204\'')).to eq('new_album_artist')
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('2')

      post '/api/track-info/21D8E2441A5E2204', { album_artist: '' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM album_artist_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_artist_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT album_artist FROM album_artist_updates')).to eq('')
      expect(get_first_value('SELECT album_artist_id FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq(nil)
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('2')

      post '/api/track-info/21D8E2441A5E2204', { album_artist: 'test_artist'}, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
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
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM album_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT album FROM album_updates')).to eq('new_album')
      expect(get_first_value('SELECT albums.name FROM tracks JOIN albums ON tracks.album_id = albums.id WHERE tracks.id=\'21D8E2441A5E2204\'')).to eq('new_album')
      expect(get_first_value('SELECT COUNT(*) FROM albums')).to eq('2')

      post '/api/track-info/21D8E2441A5E2204', { album: '' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM album_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT album FROM album_updates')).to eq('')
      expect(get_first_value('SELECT album_id FROM tracks WHERE id=\'21D8E2441A5E2204\'')).to eq(nil)
      expect(get_first_value('SELECT COUNT(*) FROM albums')).to eq('2')

      post '/api/track-info/21D8E2441A5E2204', { album: 'test_album'}, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM album_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_updates')).to eq('21D8E2441A5E2204')
      expect(get_first_value('SELECT album FROM album_updates')).to eq('test_album')
      expect(get_first_value('SELECT albums.name FROM tracks JOIN albums ON tracks.album_id = albums.id WHERE tracks.id=\'21D8E2441A5E2204\'')).to eq('test_album')
      expect(get_first_value('SELECT COUNT(*) FROM albums')).to eq('2')
    end
  end
end
