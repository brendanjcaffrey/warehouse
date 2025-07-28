# frozen_string_literal: true

ENV['RACK_ENV'] = 'test'

require 'rspec'
require 'rack/test'
require 'pg'
require 'yaml'

GET_TABLES_SQL = 'SELECT table_name FROM information_schema.tables WHERE table_schema = \'public\';'
DROP_TABLE_SQL = 'DROP TABLE IF EXISTS %s CASCADE;'
INSERT_EXPORT_FINISHED_SQL = 'INSERT INTO export_finished (finished_at) VALUES (current_timestamp)'

TestConfig = Struct.new(:music_path, :artwork_path, :database_host, :database_port, :database_username, :database_password, :database_name, :port, :secret)
if ENV['CI']
  database_username = 'ci'
  database_password = 'ci'
else
  local_config = YAML.safe_load(File.open('config.yaml'))['local']
  database_username = local_config['database_username']
  database_password = local_config['database_password']
end
database_name = 'warehouse_test'

TEST_CONFIG = TestConfig.new(__dir__, __dir__, 'localhost', 5432, database_username, database_password, database_name,
                             8046, '01c814ac4499d22193c43cd6d4c3af62cab90ec76ba14bccf896c7add0415db0')
USERNAMES = %w[test123 notrack].freeze

module Config
  module_function

  def set_remote(remote)
    @remote = remote
  end

  def remote?
    @remote
  end

  def local
    TEST_CONFIG
  end

  def env
    TEST_CONFIG
  end

  def valid_username?(username)
    USERNAMES.include?(username)
  end

  def valid_username_and_password?(username, password)
    valid_username?(username) && password == username
  end

  def track_user_changes?(username)
    username == 'test123'
  end
end

require_relative '../server'

module Update
  class Database
    attr_reader :db
  end
end

describe 'Warehouse Server' do
  include Rack::Test::Methods
  include Helpers

  def app
    Server
  end

  def default_host
    'localhost'
  end

  def get_first_value(query)
    DB_POOL.with do |conn|
      conn.exec_params(query).values.flatten.first
    end
  end

  def get_auth_header(username = 'test123')
    headers = { exp: Time.now.to_i + 5 }
    token = JWT.encode({ username: username }, TEST_CONFIG.secret, JWT_ALGO, headers)
    { 'HTTP_AUTHORIZATION' => "Bearer #{token}" }
  end

  def get_expired_auth_header(username = 'test123')
    headers = { exp: Time.now.to_i - 5 }
    token = JWT.encode({ username: username }, TEST_CONFIG.secret, JWT_ALGO, headers)
    { 'HTTP_AUTHORIZATION' => "Bearer #{token}" }
  end

  def get_invalid_auth_header
    { 'HTTP_AUTHORIZATION' => 'Bearer blah' }
  end

  def insert_old_export_finished_at
    DB_POOL.with do |conn|
      conn.exec('INSERT INTO export_finished (finished_at) VALUES (\'2020-01-01 00:00:00.000000\')')
    end
  end

  def export_finished_at
    timestamp_to_ns(get_first_value('SELECT finished_at FROM export_finished'))
  end

  before :all do
    `echo "fake mp3 contents" > "#{__dir__}/__test.mp3"`
    `echo "fake jpg contents" > "#{__dir__}/__artwork.jpg"`
    `echo "fake png contents" > "#{__dir__}/__artwork.png"`
    File.symlink(File.expand_path("#{__dir__}/__test.mp3"), "#{__dir__}/06dbe92c2a5dab2f7911e20a9e157521.mp3")

    DB_POOL.with do |conn|
      orig_tables = conn.exec(GET_TABLES_SQL).map(&:values).flatten
      orig_tables.each do |table|
        conn.exec(DROP_TABLE_SQL % conn.escape_string(table))
      end

      sql_file = "#{__dir__}/../../export/export/CreateTables.sql"
      queries = File.read(sql_file).split(';').map(&:strip).reject(&:empty?)
      queries.each do |query|
        conn.exec(query)
      end
    end
  end

  after :all do
    `rm "#{__dir__}/__test.mp3"`
    `rm "#{__dir__}/06dbe92c2a5dab2f7911e20a9e157521.mp3"`
    `rm "#{__dir__}/__artwork.jpg"`
    `rm "#{__dir__}/__artwork.png"`
  end

  let(:track_id1) { '21D8E2441A5E2204' }
  let(:track_id2) { '5E3FA18D81E469D2' }
  let(:track_id3) { 'B7F8970B634DDEE3' }
  let(:genre_id) { 100_000 }
  let(:artist_id) { 200_000 }
  let(:album_id) { 300_000 }
  let(:playlistX) { 'XXXXXXXXXXXXXXXX' }
  let(:playlist0) { '0000000000000000' }
  let(:playlist1) { '1111111111111111' }
  let(:playlist2) { '2222222222222222' }
  let(:music_filename) { '06dbe92c2a5dab2f7911e20a9e157521.mp3' }
  let(:artwork_filename) { '__artwork.jpg' }

  before do
    Server.set :environment, :test
    Server.set :raise_errors, true
    Server.set :show_exceptions, false
    Config.set_remote(false)

    DB_POOL.with do |conn|
      conn.exec('BEGIN')
      conn.exec_params('INSERT INTO genres (id, name) VALUES ($1,$2)', [genre_id, 'test_genre'])
      conn.exec_params('INSERT INTO artists (id, name, sort_name) VALUES ($1,$2,$3)', [artist_id, 'test_artist', ''])
      conn.exec_params('INSERT INTO albums (id, name, sort_name) VALUES ($1,$2,$3)', [album_id, 'test_album', ''])
      conn.exec_params('INSERT INTO tracks (id,name,sort_name,artist_id,album_artist_id,album_id,genre_id,year,duration,start,finish,track_number,disc_number,play_count,rating,music_filename,artwork_filename) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17);',
                       [track_id1, 'test_title', '', artist_id, nil, album_id, genre_id, 2018, 1.23, 0.1, 1.22, 2, 1, 5, 100, music_filename, artwork_filename])
    end
  end

  after do
    DB_POOL.with { |conn| conn.exec('ROLLBACK') }
  end

  describe '/' do
    it 'sends index.html' do
      get '/'
      expect(last_response.body).to include('Warehouse')
    end
  end

  describe '/tracks/*' do
    it 'redirects if not logged in' do
      get "/tracks/#{music_filename}"
      follow_redirect!
      expect(last_request.url).to eq('http://localhost/')
    end

    it 'returns 404 if the track does not exist in the database' do
      get '/tracks/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ', {}, get_auth_header
      expect(last_response.status).to eq(404)
    end

    it 'sends the contents of the file' do
      get "/tracks/#{music_filename}", {}, get_auth_header
      expect(last_response.body).to eq("fake mp3 contents\n")
    end

    it 'sends a path to the file in remote mode' do
      Config.set_remote(true)
      get "/tracks/#{music_filename}", {}, get_auth_header
      expect(last_response.headers['Content-Type']).to eq('audio/mpeg')
      expect(last_response.headers['X-Accel-Redirect']).to eq('/accel/music/06dbe92c2a5dab2f7911e20a9e157521.mp3')
    end
  end

  describe '/artwork/*' do
    it 'redirects if not logged in' do
      get "/artwork/#{artwork_filename}"
      follow_redirect!
      expect(last_request.url).to eq('http://localhost/')
    end

    it 'returns 404 if the artwork does not exist' do
      get '/artwork/__notfound.jpg', {}, get_auth_header
      expect(last_response.status).to eq(404)
    end

    it 'returns 404 if the file exists but is not in the database' do
      get '/artwork/__fake_artwork.jpg', {}, get_auth_header
      expect(last_response.status).to eq(404)
    end

    it 'sends the contents of the file if it is in the database' do
      get "/artwork/#{artwork_filename}", {}, get_auth_header
      expect(last_response.body).to eq("fake jpg contents\n")
    end

    it 'sends a path to the file in remote mode' do
      Config.set_remote(true)
      get "/artwork/#{artwork_filename}", {}, get_auth_header
      expect(last_response.headers['Content-Type']).to eq('image/jpeg')
      expect(last_response.headers['X-Accel-Redirect']).to eq('/accel/artwork/__artwork.jpg')
    end
  end

  describe 'post /api/auth' do
    it 'return a token' do
      post '/api/auth', { username: 'test123', password: 'test123' }
      response = AuthResponse.decode(last_response.body)
      expect(response.response).to eq(:token)
      payload, header = JWT.decode(response.token, TEST_CONFIG.secret, true, { algorithm: JWT_ALGO })
      expect(header['exp']).to be > Time.now.to_i
      expect(payload['username']).to eq('test123')
    end

    it 'rejects an invalid username' do
      post '/api/auth', { username: 'invalid', password: 'test123' }
      response = AuthResponse.decode(last_response.body)
      expect(response.response).to eq(:error)
    end

    it 'rejects an invalid password' do
      post '/api/auth', { username: 'test', password: 'invalid' }
      response = AuthResponse.decode(last_response.body)
      expect(response.response).to eq(:error)
    end
  end

  describe 'put /api/auth' do
    it 'returns a new token if valid jwt' do
      auth_header = get_auth_header
      put '/api/auth', {}, auth_header
      response = AuthResponse.decode(last_response.body)
      expect(response.response).to eq(:token)
      expect(response.token).not_to eq(auth_header['HTTP_AUTHORIZATION'])

      payload, header = JWT.decode(response.token, TEST_CONFIG.secret, true, { algorithm: JWT_ALGO })
      expect(header['exp']).to be > Time.now.to_i
      expect(payload['username']).to eq('test123')
    end

    it 'returns an error if no auth header' do
      put '/api/auth'
      expect(AuthResponse.decode(last_response.body).response).to eq(:error)
    end

    it 'returns false if expired jwt' do
      put '/api/auth', {}, get_expired_auth_header
      expect(AuthResponse.decode(last_response.body).response).to eq(:error)
    end

    it 'returns false if invalid jwt' do
      put '/api/auth', {}, get_invalid_auth_header
      expect(AuthResponse.decode(last_response.body).response).to eq(:error)
    end
  end

  describe 'get /api/version' do
    it 'returns an error if no jwt' do
      get '/api/version'
      expect(VersionResponse.decode(last_response.body).response).to eq(:error)
    end

    it 'returns an error if invalid jwt' do
      get '/api/version', {}, get_invalid_auth_header
      expect(VersionResponse.decode(last_response.body).response).to eq(:error)
    end

    it 'returns an error if expired jwt' do
      get '/api/version', {}, get_expired_auth_header
      expect(VersionResponse.decode(last_response.body).response).to eq(:error)
    end

    it 'returns 500 if the export did not finish' do
      get '/api/version', {}, get_auth_header
      expect(last_response.status).to eq(500)
    end

    it 'returns the time if the export did finish' do
      DB_POOL.with do |conn|
        conn.exec(INSERT_EXPORT_FINISHED_SQL)
      end

      get '/api/version', {}, get_auth_header
      version = VersionResponse.decode(last_response.body)
      expect(version.response).to eq(:updateTimeNs)
      expect(version.updateTimeNs).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end
  end

  describe 'get /api/library' do
    before do
      DB_POOL.with do |conn|
        conn.exec_params('INSERT INTO library_metadata (total_file_size) VALUES ($1)', [1001])
      end
    end

    it 'returns an error if no jwt' do
      get '/api/library'
      expect(LibraryResponse.decode(last_response.body).response).to eq(:error)
    end

    it 'returns an error if invalid jwt' do
      get '/api/library', {}, get_invalid_auth_header
      expect(LibraryResponse.decode(last_response.body).response).to eq(:error)
    end

    it 'returns an error if expired jwt' do
      get '/api/library', {}, get_expired_auth_header
      expect(LibraryResponse.decode(last_response.body).response).to eq(:error)
    end

    it 'returns a 500 if the export did not finish' do
      get '/api/library', {}, get_auth_header
      expect(last_response.status).to eq(500)
    end

    it 'dumps all genres, artists, albums and tracks' do
      DB_POOL.with do |conn|
        conn.exec(INSERT_EXPORT_FINISHED_SQL)
        conn.exec_params('INSERT INTO playlists (id, name, is_library, parent_id) VALUES ($1,$2,$3,$4),($5,$6,$7,$8),($9,$10,$11,$12),($13,$14,$15,$16)',
                         [
                           playlistX, 'library', 1, '',
                           playlist0, 'test_playlist0', 0, '',
                           playlist1, 'test_playlist1', 0, playlist0,
                           playlist2, 'test_playlist2', 0, ''
                         ])
        conn.exec_params('INSERT INTO playlist_tracks (playlist_id, track_id) VALUES ($1,$2),($3,$4),($5,$6)',
                         [playlist1, track_id3, playlist2, track_id2, playlist2, track_id1])
      end

      get '/api/library', {}, get_auth_header
      library = LibraryResponse.decode(last_response.body).library

      expect(library.genres.length).to eq(1)
      expect(library.genres[genre_id].name).to eq('test_genre')

      expect(library.artists.length).to eq(1)
      expect(library.artists[artist_id].name).to eq('test_artist')
      expect(library.artists[artist_id].sortName).to eq('')

      expect(library.albums.length).to eq(1)
      library.albums.keys.first
      expect(library.albums[album_id].name).to eq('test_album')
      expect(library.albums[album_id].sortName).to eq('')

      expect(library.tracks.length).to eq(1)
      track = library.tracks.first
      expect(track.id).to eq(track_id1)
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
      expect(track.musicFilename).to eq('06dbe92c2a5dab2f7911e20a9e157521.mp3')
      expect(track.artworkFilename).to eq('__artwork.jpg')
      expect(track.playlistIds).to eq([playlist2, playlistX])

      expect(library.playlists.length).to eq(4)
      playlist = library.playlists[0]
      expect(playlist.id).to eq(playlistX)
      expect(playlist.name).to eq('library')
      expect(playlist.parentId).to eq('')
      expect(playlist.isLibrary).to be(true)
      expect(playlist.trackIds).to eq([])

      playlist = library.playlists[1]
      expect(playlist.id).to eq(playlist2)
      expect(playlist.name).to eq('test_playlist2')
      expect(playlist.parentId).to eq('')
      expect(playlist.isLibrary).to be(false)
      expect(playlist.trackIds).to eq([track_id2, track_id1])

      playlist = library.playlists[2]
      expect(playlist.id).to eq(playlist1)
      expect(playlist.name).to eq('test_playlist1')
      expect(playlist.parentId).to eq(playlist0)
      expect(playlist.isLibrary).to be(false)
      expect(playlist.trackIds).to eq([track_id3])

      playlist = library.playlists[3]
      expect(playlist.id).to eq(playlist0)
      expect(playlist.name).to eq('test_playlist0')
      expect(playlist.parentId).to eq('')
      expect(playlist.isLibrary).to be(false)
      expect(playlist.trackIds).to eq([])

      expect(library.totalFileSize).to eq(1001)
      expect(library.updateTimeNs).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end

    it 'includes whether to track changes or not' do
      DB_POOL.with do |conn|
        conn.exec(INSERT_EXPORT_FINISHED_SQL)
      end
      get '/api/library', {}, get_auth_header('test123')
      library = LibraryResponse.decode(last_response.body).library
      expect(library.trackUserChanges).to be true

      get '/api/library', {}, get_auth_header('notrack')
      library = LibraryResponse.decode(last_response.body).library
      expect(library.trackUserChanges).to be false
    end

    it 'supports missing artwork' do
      DB_POOL.with do |conn|
        conn.exec(INSERT_EXPORT_FINISHED_SQL)
        conn.exec('UPDATE tracks SET artwork_filename=NULL')
      end
      get '/api/library', {}, get_auth_header
      library = LibraryResponse.decode(last_response.body).library
      expect(library.tracks[0].artworkFilename).to eq('')
    end
  end

  describe '/api/updates' do
    it 'returns an error if no jwt' do
      get '/api/updates'
      expect(UpdatesResponse.decode(last_response.body).response).to eq(:error)
    end

    it 'returns an error if invalid jwt' do
      get '/api/updates', {}, get_invalid_auth_header
      expect(UpdatesResponse.decode(last_response.body).response).to eq(:error)
    end

    it 'returns an error if expired jwt' do
      get '/api/updates', {}, get_expired_auth_header
      expect(UpdatesResponse.decode(last_response.body).response).to eq(:error)
    end

    it 'includes all plays' do
      DB_POOL.with do |conn|
        conn.exec('INSERT INTO plays (track_id) VALUES ($1);', [track_id2])
        conn.exec('INSERT INTO plays (track_id) VALUES ($1);', [track_id1])
        conn.exec('INSERT INTO plays (track_id) VALUES ($1);', [track_id2])
      end

      get '/api/updates', {}, get_auth_header
      updates = UpdatesResponse.decode(last_response.body).updates
      expect(updates.plays.map(&:trackId)).to eq([track_id2, track_id1, track_id2])
    end

    it 'includes all ratings' do
      DB_POOL.with do |conn|
        conn.exec('INSERT INTO rating_updates (track_id, rating) VALUES ($1, $2);', [track_id2, 100])
        conn.exec('INSERT INTO rating_updates (track_id, rating) VALUES ($1, $2);', [track_id1, 80])
        conn.exec('INSERT INTO rating_updates (track_id, rating) VALUES ($1, $2);', [track_id2, 60])
      end

      get '/api/updates', {}, get_auth_header
      ratings = UpdatesResponse.decode(last_response.body).updates.ratings
      expect(ratings.map(&:trackId)).to eq([track_id2, track_id1, track_id2])
      expect(ratings.map(&:value)).to eq([100, 80, 60])
    end

    it 'includes all names' do
      DB_POOL.with do |conn|
        conn.exec('INSERT INTO name_updates (track_id, name) VALUES ($1, $2);', [track_id2, 'abc'])
        conn.exec('INSERT INTO name_updates (track_id, name) VALUES ($1, $2);', [track_id1, 'def'])
        conn.exec('INSERT INTO name_updates (track_id, name) VALUES ($1, $2);', [track_id2, 'ghi'])
      end

      get '/api/updates', {}, get_auth_header
      names = UpdatesResponse.decode(last_response.body).updates.names
      expect(names.map(&:trackId)).to eq([track_id2, track_id1, track_id2])
      expect(names.map(&:value)).to eq(%w[abc def ghi])
    end

    it 'includes all artists' do
      DB_POOL.with do |conn|
        conn.exec('INSERT INTO artist_updates (track_id, artist) VALUES ($1, $2);', [track_id2, 'abc'])
        conn.exec('INSERT INTO artist_updates (track_id, artist) VALUES ($1, $2);', [track_id1, 'def'])
        conn.exec('INSERT INTO artist_updates (track_id, artist) VALUES ($1, $2);', [track_id2, 'ghi'])
      end

      get '/api/updates', {}, get_auth_header
      artists = UpdatesResponse.decode(last_response.body).updates.artists
      expect(artists.map(&:trackId)).to eq([track_id2, track_id1, track_id2])
      expect(artists.map(&:value)).to eq(%w[abc def ghi])
    end

    it 'includes all albums' do
      DB_POOL.with do |conn|
        conn.exec('INSERT INTO album_updates (track_id, album) VALUES ($1, $2);', [track_id2, 'abc'])
        conn.exec('INSERT INTO album_updates (track_id, album) VALUES ($1, $2);', [track_id1, 'def'])
        conn.exec('INSERT INTO album_updates (track_id, album) VALUES ($1, $2);', [track_id2, 'ghi'])
      end

      get '/api/updates', {}, get_auth_header
      albums = UpdatesResponse.decode(last_response.body).updates.albums
      expect(albums.map(&:trackId)).to eq([track_id2, track_id1, track_id2])
      expect(albums.map(&:value)).to eq(%w[abc def ghi])
    end

    it 'includes all album artists' do
      DB_POOL.with do |conn|
        conn.exec('INSERT INTO album_artist_updates (track_id, album_artist) VALUES ($1, $2);', [track_id2, 'abc'])
        conn.exec('INSERT INTO album_artist_updates (track_id, album_artist) VALUES ($1, $2);', [track_id1, 'def'])
        conn.exec('INSERT INTO album_artist_updates (track_id, album_artist) VALUES ($1, $2);', [track_id2, 'ghi'])
      end

      get '/api/updates', {}, get_auth_header
      album_artists = UpdatesResponse.decode(last_response.body).updates.albumArtists
      expect(album_artists.map(&:trackId)).to eq([track_id2, track_id1, track_id2])
      expect(album_artists.map(&:value)).to eq(%w[abc def ghi])
    end

    it 'includes all genres' do
      DB_POOL.with do |conn|
        conn.exec('INSERT INTO genre_updates (track_id, genre) VALUES ($1, $2);', [track_id2, 'abc'])
        conn.exec('INSERT INTO genre_updates (track_id, genre) VALUES ($1, $2);', [track_id1, 'def'])
        conn.exec('INSERT INTO genre_updates (track_id, genre) VALUES ($1, $2);', [track_id2, 'ghi'])
      end

      get '/api/updates', {}, get_auth_header
      genres = UpdatesResponse.decode(last_response.body).updates.genres
      expect(genres.map(&:trackId)).to eq([track_id2, track_id1, track_id2])
      expect(genres.map(&:value)).to eq(%w[abc def ghi])
    end

    it 'includes all years' do
      DB_POOL.with do |conn|
        conn.exec('INSERT INTO year_updates (track_id, year) VALUES ($1, $2);', [track_id2, 100])
        conn.exec('INSERT INTO year_updates (track_id, year) VALUES ($1, $2);', [track_id1, 200])
        conn.exec('INSERT INTO year_updates (track_id, year) VALUES ($1, $2);', [track_id2, 300])
      end

      get '/api/updates', {}, get_auth_header
      years = UpdatesResponse.decode(last_response.body).updates.years
      expect(years.map(&:trackId)).to eq([track_id2, track_id1, track_id2])
      expect(years.map(&:value)).to eq([100, 200, 300])
    end

    it 'includes all starts' do
      DB_POOL.with do |conn|
        conn.exec('INSERT INTO start_updates (track_id, start) VALUES ($1, $2);', [track_id2, 1.1])
        conn.exec('INSERT INTO start_updates (track_id, start) VALUES ($1, $2);', [track_id1, 1.2])
        conn.exec('INSERT INTO start_updates (track_id, start) VALUES ($1, $2);', [track_id2, 1.3])
      end

      get '/api/updates', {}, get_auth_header
      starts = UpdatesResponse.decode(last_response.body).updates.starts
      expect(starts.map(&:trackId)).to eq([track_id2, track_id1, track_id2])
      expect(starts[0].value).to be_within(0.001).of(1.1)
      expect(starts[1].value).to be_within(0.001).of(1.2)
      expect(starts[2].value).to be_within(0.001).of(1.3)
    end

    it 'includes all finishes' do
      DB_POOL.with do |conn|
        conn.exec('INSERT INTO finish_updates (track_id, finish) VALUES ($1, $2);', [track_id2, 1.1])
        conn.exec('INSERT INTO finish_updates (track_id, finish) VALUES ($1, $2);', [track_id1, 1.2])
        conn.exec('INSERT INTO finish_updates (track_id, finish) VALUES ($1, $2);', [track_id2, 1.3])
      end

      get '/api/updates', {}, get_auth_header
      finishes = UpdatesResponse.decode(last_response.body).updates.finishes
      expect(finishes.map(&:trackId)).to eq([track_id2, track_id1, track_id2])
      expect(finishes[0].value).to be_within(0.001).of(1.1)
      expect(finishes[1].value).to be_within(0.001).of(1.2)
      expect(finishes[2].value).to be_within(0.001).of(1.3)
    end

    it 'includes all artwork updates' do
      DB_POOL.with do |conn|
        conn.exec('INSERT INTO artwork_updates (track_id, artwork_filename) VALUES ($1, $2);', [track_id2, 'hi.jpg'])
        conn.exec('INSERT INTO artwork_updates (track_id, artwork_filename) VALUES ($1, $2);', [track_id1, nil])
        conn.exec('INSERT INTO artwork_updates (track_id, artwork_filename) VALUES ($1, $2);', [track_id2, 'hello.png'])
      end

      get '/api/updates', {}, get_auth_header
      artworks = UpdatesResponse.decode(last_response.body).updates.artworks
      expect(artworks.map(&:trackId)).to eq([track_id2, track_id1, track_id2])
      expect(artworks[0].value.strip).to eq('hi.jpg')
      expect(artworks[1].value).to eq('')
      expect(artworks[2].value.strip).to eq('hello.png')
    end
  end

  describe '/api/play/*' do
    it 'returns an error if no jwt' do
      post "/api/play/#{track_id1}"
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'returns an error if invalid jwt' do
      post "/api/play/#{track_id1}", {}, get_invalid_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'returns an error if expired jwt' do
      post "/api/play/#{track_id1}", {}, get_expired_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'returns an error if not tracking this users changes' do
      post "/api/play/#{track_id1}", {}, get_auth_header('notrack')
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_TRACKING_ERROR)
    end

    it 'returns an error if track does not exist' do
      post '/api/play/ABCD', {}, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_TRACK_ERROR)
    end

    it 'creates a play if tracking this users changes is enabled' do
      insert_old_export_finished_at
      expect(get_first_value("SELECT play_count FROM tracks WHERE id='#{track_id1}'")).to eq('5')

      post "/api/play/#{track_id1}", {}, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM plays')).to eq('1')
      expect(get_first_value('SELECT track_id FROM plays')).to eq(track_id1)
      expect(get_first_value("SELECT play_count FROM tracks WHERE id='#{track_id1}'")).to eq('6')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end
  end

  describe '/api/rating/*' do
    it 'returns an error if rating is missing' do
      post "/api/rating/#{track_id1}", {}, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_RATING_ERROR)
    end

    it 'returns an error if rating is non-numeric' do
      post "/api/rating/#{track_id1}", { rating: 'abcd' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_RATING_ERROR)
    end

    it 'returns an error if rating is empty' do
      post "/api/rating/#{track_id1}", { rating: '' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_RATING_ERROR)
    end

    it 'returns an error if rating is too high' do
      post "/api/rating/#{track_id1}", { rating: '120' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_RATING_ERROR)
    end

    it 'returns an error if rating is too low' do
      post "/api/rating/#{track_id1}", { rating: '-1' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_RATING_ERROR)
    end

    it 'returns an error if no jwt' do
      post "/api/rating/#{track_id1}", { rating: '80' }
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'returns an error if invalid jwt' do
      post "/api/rating/#{track_id1}", { rating: '80' }, get_invalid_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'returns an error if expired jwt' do
      post "/api/rating/#{track_id1}", { rating: '80' }, get_expired_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'returns an error if not tracking this users changes' do
      post "/api/rating/#{track_id1}", { rating: '80' }, get_auth_header('notrack')
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_TRACKING_ERROR)
    end

    it 'returns an error if track does not exist' do
      post '/api/rating/ABCD', { rating: '80' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_TRACK_ERROR)
    end

    it 'creates a rating update if tracking this users changes is enabled' do
      insert_old_export_finished_at
      expect(get_first_value("SELECT rating FROM tracks WHERE id='#{track_id1}'")).to eq('100')

      post "/api/rating/#{track_id1}", { rating: '80' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM rating_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM rating_updates')).to eq(track_id1)
      expect(get_first_value('SELECT rating FROM rating_updates')).to eq('80')
      expect(get_first_value("SELECT rating FROM tracks WHERE id='#{track_id1}'")).to eq('80')

      post "/api/rating/#{track_id1}", { rating: '100' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM rating_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM rating_updates')).to eq(track_id1)
      expect(get_first_value('SELECT rating FROM rating_updates')).to eq('100')
      expect(get_first_value("SELECT rating FROM tracks WHERE id='#{track_id1}'")).to eq('100')

      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end
  end

  describe '/api/track-info/*' do
    before do
      insert_old_export_finished_at
    end

    it 'returns an error if no jwt' do
      post "/api/track-info/#{track_id1}"
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'returns an error if invalid jwt' do
      post "/api/track-info/#{track_id1}", {}, get_invalid_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'returns an error if expired jwt' do
      post "/api/track-info/#{track_id1}", {}, get_expired_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'returns an error if not tracking the users changes' do
      post "/api/track-info/#{track_id1}", {}, get_auth_header('notrack')
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_TRACKING_ERROR)
    end

    it 'returns an error if track does not exist' do
      post '/api/track-info/ABCD', {}, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_TRACK_ERROR)
    end

    it 'returns an error if name is empty' do
      post '/api/track-info/ABCD', { name: '' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(TRACK_FIELD_MISSING_ERROR)
    end

    it 'returns an error if year is empty' do
      post '/api/track-info/ABCD', { year: '' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(TRACK_FIELD_MISSING_ERROR)
    end

    it 'returns an error if artist is empty' do
      post '/api/track-info/ABCD', { artist: '' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(TRACK_FIELD_MISSING_ERROR)
    end

    it 'returns an error if genre is empty' do
      post '/api/track-info/ABCD', { genre: '' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(TRACK_FIELD_MISSING_ERROR)
    end

    it 'returns an error if year is non-numeric' do
      post '/api/track-info/ABCD', { year: 'abcd' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_YEAR_ERROR)
    end

    it 'returns an error if artwork file does not exist' do
      post '/api/track-info/ABCD', { artwork: 'abcd.png' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(MISSING_FILE_ERROR)
    end

    it 'creates a name update if tracking this users changes is enabled' do
      expect(get_first_value("SELECT name FROM tracks WHERE id='#{track_id1}'")).to eq('test_title')

      post "/api/track-info/#{track_id1}", { name: 'abc' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM name_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM name_updates')).to eq(track_id1)
      expect(get_first_value('SELECT name FROM name_updates')).to eq('abc')
      expect(get_first_value("SELECT name FROM tracks WHERE id='#{track_id1}'")).to eq('abc')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)

      post "/api/track-info/#{track_id1}", { name: 'test_title' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM name_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM name_updates')).to eq(track_id1)
      expect(get_first_value('SELECT name FROM name_updates')).to eq('test_title')
      expect(get_first_value("SELECT name FROM tracks WHERE id='#{track_id1}'")).to eq('test_title')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end

    it 'creates a year update if tracking this users changes is enabled' do
      expect(get_first_value("SELECT year FROM tracks WHERE id='#{track_id1}'")).to eq('2018')

      post "/api/track-info/#{track_id1}", { year: '1970' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM year_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM year_updates')).to eq(track_id1)
      expect(get_first_value('SELECT year FROM year_updates')).to eq('1970')
      expect(get_first_value("SELECT year FROM tracks WHERE id='#{track_id1}'")).to eq('1970')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)

      post "/api/track-info/#{track_id1}", { year: '1990' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM year_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM year_updates')).to eq(track_id1)
      expect(get_first_value('SELECT year FROM year_updates')).to eq('1990')
      expect(get_first_value("SELECT year FROM tracks WHERE id='#{track_id1}'")).to eq('1990')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end

    it 'creates a start update if tracking this users changes is enabled' do
      expect(get_first_value("SELECT start FROM tracks WHERE id='#{track_id1}'")).to eq('0.1')

      post "/api/track-info/#{track_id1}", { start: '1.2' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM start_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM start_updates')).to eq(track_id1)
      expect(get_first_value('SELECT start FROM start_updates')).to eq('1.2')
      expect(get_first_value("SELECT start FROM tracks WHERE id='#{track_id1}'")).to eq('1.2')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)

      post "/api/track-info/#{track_id1}", { start: '1.3' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM start_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM start_updates')).to eq(track_id1)
      expect(get_first_value('SELECT start FROM start_updates')).to eq('1.3')
      expect(get_first_value("SELECT start FROM tracks WHERE id='#{track_id1}'")).to eq('1.3')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end

    it 'creates a finish update if tracking this users changes is enabled' do
      expect(get_first_value("SELECT finish FROM tracks WHERE id='#{track_id1}'")).to eq('1.22')

      post "/api/track-info/#{track_id1}", { finish: '2.3' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM finish_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM finish_updates')).to eq(track_id1)
      expect(get_first_value('SELECT finish FROM finish_updates')).to eq('2.3')
      expect(get_first_value("SELECT finish FROM tracks WHERE id='#{track_id1}'")).to eq('2.3')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)

      post "/api/track-info/#{track_id1}", { finish: '2.4' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM finish_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM finish_updates')).to eq(track_id1)
      expect(get_first_value('SELECT finish FROM finish_updates')).to eq('2.4')
      expect(get_first_value("SELECT finish FROM tracks WHERE id='#{track_id1}'")).to eq('2.4')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end

    it 'creates an artist update if tracking this users changes is enabled' do
      expect(get_first_value("SELECT artists.name FROM tracks JOIN artists ON tracks.artist_id = artists.id WHERE tracks.id='#{track_id1}'")).to eq('test_artist')
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('1')

      post "/api/track-info/#{track_id1}", { artist: 'new_artist' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM artist_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM artist_updates')).to eq(track_id1)
      expect(get_first_value('SELECT artist FROM artist_updates')).to eq('new_artist')
      expect(get_first_value("SELECT artists.name FROM tracks JOIN artists ON tracks.artist_id = artists.id WHERE tracks.id='#{track_id1}'")).to eq('new_artist')
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('2')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)

      post "/api/track-info/#{track_id1}", { artist: 'test_artist' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM artist_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM artist_updates')).to eq(track_id1)
      expect(get_first_value('SELECT artist FROM artist_updates')).to eq('test_artist')
      expect(get_first_value("SELECT artists.name FROM tracks JOIN artists ON tracks.artist_id = artists.id WHERE tracks.id='#{track_id1}'")).to eq('test_artist')
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('2')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end

    it 'creates an genre update if tracking this users changes is enabled' do
      expect(get_first_value("SELECT genres.name FROM tracks JOIN genres ON tracks.genre_id = genres.id WHERE tracks.id='#{track_id1}'")).to eq('test_genre')
      expect(get_first_value('SELECT COUNT(*) FROM genres')).to eq('1')

      post "/api/track-info/#{track_id1}", { genre: 'new_genre' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM genre_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM genre_updates')).to eq(track_id1)
      expect(get_first_value('SELECT genre FROM genre_updates')).to eq('new_genre')
      expect(get_first_value("SELECT genres.name FROM tracks JOIN genres ON tracks.genre_id = genres.id WHERE tracks.id='#{track_id1}'")).to eq('new_genre')
      expect(get_first_value('SELECT COUNT(*) FROM genres')).to eq('2')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)

      post "/api/track-info/#{track_id1}", { genre: 'test_genre' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM genre_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM genre_updates')).to eq(track_id1)
      expect(get_first_value('SELECT genre FROM genre_updates')).to eq('test_genre')
      expect(get_first_value("SELECT genres.name FROM tracks JOIN genres ON tracks.genre_id = genres.id WHERE tracks.id='#{track_id1}'")).to eq('test_genre')
      expect(get_first_value('SELECT COUNT(*) FROM genres')).to eq('2')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end

    it 'creates an album artist update if tracking this users changes is enabled' do
      expect(get_first_value("SELECT album_artist_id FROM tracks WHERE tracks.id='#{track_id1}'")).to be_nil
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('1')

      post "/api/track-info/#{track_id1}", { album_artist: 'new_album_artist' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM album_artist_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_artist_updates')).to eq(track_id1)
      expect(get_first_value('SELECT album_artist FROM album_artist_updates')).to eq('new_album_artist')
      expect(get_first_value("SELECT artists.name FROM tracks JOIN artists ON tracks.album_artist_id = artists.id WHERE tracks.id='#{track_id1}'")).to eq('new_album_artist')
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('2')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)

      post "/api/track-info/#{track_id1}", { album_artist: '' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM album_artist_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_artist_updates')).to eq(track_id1)
      expect(get_first_value('SELECT album_artist FROM album_artist_updates')).to eq('')
      expect(get_first_value("SELECT album_artist_id FROM tracks WHERE id='#{track_id1}'")).to be_nil
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('2')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)

      post "/api/track-info/#{track_id1}", { album_artist: 'test_artist' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM album_artist_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_artist_updates')).to eq(track_id1)
      expect(get_first_value('SELECT album_artist FROM album_artist_updates')).to eq('test_artist')
      expect(get_first_value("SELECT artists.name FROM tracks JOIN artists ON tracks.album_artist_id = artists.id WHERE tracks.id='#{track_id1}'")).to eq('test_artist')
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('2')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end

    it 'creates an album update if tracking this users changes is enabled' do
      expect(get_first_value("SELECT albums.name FROM tracks JOIN albums ON tracks.album_id = albums.id WHERE tracks.id='#{track_id1}'")).to eq('test_album')
      expect(get_first_value('SELECT COUNT(*) FROM albums')).to eq('1')

      post "/api/track-info/#{track_id1}", { album: 'new_album' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM album_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_updates')).to eq(track_id1)
      expect(get_first_value('SELECT album FROM album_updates')).to eq('new_album')
      expect(get_first_value("SELECT albums.name FROM tracks JOIN albums ON tracks.album_id = albums.id WHERE tracks.id='#{track_id1}'")).to eq('new_album')
      expect(get_first_value('SELECT COUNT(*) FROM albums')).to eq('2')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)

      post "/api/track-info/#{track_id1}", { album: '' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM album_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_updates')).to eq(track_id1)
      expect(get_first_value('SELECT album FROM album_updates')).to eq('')
      expect(get_first_value("SELECT album_id FROM tracks WHERE id='#{track_id1}'")).to be_nil
      expect(get_first_value('SELECT COUNT(*) FROM albums')).to eq('2')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)

      post "/api/track-info/#{track_id1}", { album: 'test_album' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM album_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_updates')).to eq(track_id1)
      expect(get_first_value('SELECT album FROM album_updates')).to eq('test_album')
      expect(get_first_value("SELECT albums.name FROM tracks JOIN albums ON tracks.album_id = albums.id WHERE tracks.id='#{track_id1}'")).to eq('test_album')
      expect(get_first_value('SELECT COUNT(*) FROM albums')).to eq('2')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end

    it 'creates an artwork update if tracking this users changes' do
      expect(get_first_value("SELECT artwork_filename FROM tracks WHERE id='#{track_id1}'").strip).to eq('__artwork.jpg')

      post "/api/track-info/#{track_id1}", { artwork: '__artwork.png' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM artwork_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM artwork_updates')).to eq(track_id1)
      expect(get_first_value('SELECT artwork_filename FROM artwork_updates').strip).to eq('__artwork.png')
      expect(get_first_value("SELECT artwork_filename FROM tracks WHERE id='#{track_id1}'").strip).to eq('__artwork.png')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)

      post "/api/track-info/#{track_id1}", { artwork: '' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM artwork_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM artwork_updates')).to eq(track_id1)
      expect(get_first_value('SELECT artwork_filename FROM artwork_updates')).to be_nil
      expect(get_first_value("SELECT artwork_filename FROM tracks WHERE id='#{track_id1}'")).to be_nil
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end
  end

  describe '/api/artwork' do
    let(:artwork_filename1) { '27a8d4658b73d9533c1db34ee2350da0.jpg' }
    let(:artwork_filename2) { 'f693282ce0329b1fb9ec383feae8088b.png' }

    after do
      FileUtils.rm_f("#{__dir__}/#{artwork_filename1}")
      FileUtils.rm_f("#{__dir__}/#{artwork_filename2}")
    end

    it 'returns an error if no jwt' do
      post '/api/artwork', 'file' => Rack::Test::UploadedFile.new("#{__dir__}/__artwork.jpg", 'image/jpeg')
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'returns an error if invalid jwt' do
      post '/api/artwork', {}, get_invalid_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'returns an error if expired jwt' do
      post '/api/artwork', {}, get_expired_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'returns an error if not tracking the users changes' do
      post '/api/artwork', {}, get_auth_header('notrack')
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_TRACKING_ERROR)
    end

    it 'returns an error if missing the file' do
      post '/api/artwork', {}, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(MISSING_FILE_ERROR)
    end

    it 'returns an error if an invalid extension' do
      invalid_ext_uploaded_file = Rack::Test::UploadedFile.new("#{__dir__}/__artwork.jpg", 'image/wav', true, original_filename: 'artwork.wav')
      post '/api/artwork', { 'file' => invalid_ext_uploaded_file }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_MIME_ERROR)
    end

    it 'returns an error if the md5 does not match the filename' do
      invalid_md5_uploaded_file = Rack::Test::UploadedFile.new("#{__dir__}/__artwork.jpg", 'image/jpeg', true, original_filename: '49f68a5c8493ec2c0bf489821c21fc3b.jpg')
      post '/api/artwork', { 'file' => invalid_md5_uploaded_file }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_MD5_ERROR)
    end

    it 'accepts a valid jpg' do
      expect(File.exist?("#{__dir__}/#{artwork_filename1}")).to be false
      jpg_uploaded_file = Rack::Test::UploadedFile.new("#{__dir__}/__artwork.jpg", 'image/jpeg', true, original_filename: artwork_filename1)
      post '/api/artwork', { 'file' => jpg_uploaded_file }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be true
      expect(File.read("#{__dir__}/#{artwork_filename1}")).to eq("fake jpg contents\n")
    end

    it 'accepts a valid png' do
      expect(File.exist?("#{__dir__}/#{artwork_filename2}")).to be false
      png_uploaded_file = Rack::Test::UploadedFile.new("#{__dir__}/__artwork.png", 'image/png', true, original_filename: artwork_filename2)
      post '/api/artwork', { 'file' => png_uploaded_file }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be true
      expect(File.read("#{__dir__}/#{artwork_filename2}")).to eq("fake png contents\n")
    end
  end
end
