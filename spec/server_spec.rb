# frozen_string_literal: true

ENV['RACK_ENV'] = 'test'

require 'rspec'
require 'rack/test'
require 'pg'
require 'yaml'
require_relative '../shared/messages_pb'

GET_TABLES_SQL = 'SELECT table_name FROM information_schema.tables WHERE table_schema = \'public\';'
DROP_TABLE_SQL = 'DROP TABLE IF EXISTS %s;'
INSERT_EXPORT_FINISHED_SQL = 'INSERT INTO export_finished (finished_at) VALUES (current_timestamp)'

TestConfig = Struct.new(:music_path, :artwork_path, :database_username, :database_password, :database_name, :port, :secret)
if ENV['CI']
  database_username = 'ci'
  database_password = 'ci'
else
  local_config = YAML.safe_load(File.open('config.yaml'))['local']
  database_username = local_config['database_username']
  database_password = local_config['database_password']
end
database_name = 'warehouse_test'

TEST_CONFIG = TestConfig.new("#{Dir.pwd}/spec/", "#{Dir.pwd}/spec/", database_username, database_password, database_name,
                             8046, '01c814ac4499d22193c43cd6d4c3af62cab90ec76ba14bccf896c7add0415db0')
USERNAMES = %w[test123 notrack]

module Config
  module_function

  def remote?
    false
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
require_relative '../update/database'

module Update
  class Database
    attr_reader :db
  end
end

describe 'Warehouse Server' do
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
    @db.exec('INSERT INTO export_finished (finished_at) VALUES (\'2020-01-01 00:00:00.000000\')')
  end

  def export_finished_at
    timestamp_to_ns(get_first_value('SELECT finished_at FROM export_finished'))
  end

  before :all do
    `echo "fake mp3 contents" > spec/__test.mp3`
    `echo "fake jpg contents" > spec/__artwork.jpg`
    `echo "fake png contents" > spec/__artwork.png`
    @database = Update::Database.new(TEST_CONFIG.database_username, TEST_CONFIG.database_password, TEST_CONFIG.database_name)
    @db = @database.db

    orig_tables = @db.exec(GET_TABLES_SQL).values.flatten
    orig_tables.each do |table|
      @db.exec(DROP_TABLE_SQL % @db.escape_string(table))
    end

    sql_file = "#{Dir.pwd}/export/export/CreateTables.sql"
    queries = File.read(sql_file).split(';').map(&:strip).reject(&:empty?)
    queries.each do |query|
      @db.exec(query)
    end

    @tables = @db.exec(GET_TABLES_SQL).values.flatten
  end

  after :all do
    `rm spec/__test.mp3`
    `rm spec/__artwork.jpg`
    `rm spec/__artwork.png`
  end

  before :each do
    Server.set :environment, :test
    Server.set :raise_errors, true
    Server.set :show_exceptions, false

    @tables.each do |table|
      @db.exec("DELETE FROM #{@db.escape_string(table)}")
    end

    @track_id = '21D8E2441A5E2204'
    @genre_id = 100_000
    @artist_id = 200_000
    @album_id = 300_000

    file_path = '__test.mp3'
    @db.exec_params('INSERT INTO genres (id, name) VALUES ($1,$2)', [@genre_id, 'test_genre'])
    @db.exec_params('INSERT INTO artists (id, name, sort_name) VALUES ($1,$2,$3)', [@artist_id, 'test_artist', ''])
    @db.exec_params('INSERT INTO albums (id, name, sort_name) VALUES ($1,$2,$3)', [@album_id, 'test_album', ''])
    @db.exec_params('INSERT INTO tracks (id,name,sort_name,artist_id,album_artist_id,album_id,genre_id,year,duration,start,finish,track_number,disc_number,play_count,rating,ext,file,file_md5,artwork_filename) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19);',
                    [@track_id, 'test_title', '', @artist_id, nil, @album_id, @genre_id, 2018, 1.23, 0.1, 1.22, 2, 1, 5, 100, 'mp3', file_path, '06dbe92c2a5dab2f7911e20a9e157521', '__artwork.jpg'])

    @track_id2 = '5E3FA18D81E469D2'
  end

  describe '/' do
    it 'sends index.html' do
      get '/'
      expect(last_response.body).to include('Warehouse')
    end
  end

  describe '/tracks/*' do
    it 'should redirect if not logged in' do
      get '/tracks/06dbe92c2a5dab2f7911e20a9e157521'
      follow_redirect!
      expect(last_request.url).to eq('http://localhost/')
    end

    it 'should 404 if the track doesn\'t exist in the database' do
      get '/tracks/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ', {}, get_auth_header
      expect(last_response.status).to eq(404)
    end

    it 'should send the contents of the file' do
      get '/tracks/06dbe92c2a5dab2f7911e20a9e157521', {}, get_auth_header
      expect(last_response.body).to eq("fake mp3 contents\n")
    end
  end

  describe '/artwork/*' do
    it 'should redirect if not logged in' do
      get '/artwork/__artwork.jpg'
      follow_redirect!
      expect(last_request.url).to eq('http://localhost/')
    end

    it 'should 404 if the artwork doesn\'t exist' do
      get '/artwork/__notfound.jpg', {}, get_auth_header
      expect(last_response.status).to eq(404)
    end

    it 'should 404 if the file exists but isn\'t in the database' do
      get '/artwork/__fake_artwork.jpg', {}, get_auth_header
      expect(last_response.status).to eq(404)
    end

    it 'should send the contents of the file if it is in the database' do
      get '/artwork/__artwork.jpg', {}, get_auth_header
      expect(last_response.body).to eq("fake jpg contents\n")
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

    it 'should reject an invalid username' do
      post '/api/auth', { username: 'invalid', password: 'test123' }
      response = AuthResponse.decode(last_response.body)
      expect(response.response).to eq(:error)
    end

    it 'should reject an invalid password' do
      post '/api/auth', { username: 'test', password: 'invalid' }
      response = AuthResponse.decode(last_response.body)
      expect(response.response).to eq(:error)
    end
  end

  describe 'put /api/auth' do
    it 'should return a new token if valid jwt' do
      auth_header = get_auth_header
      put '/api/auth', {}, auth_header
      response = AuthResponse.decode(last_response.body)
      expect(response.response).to eq(:token)
      expect(response.token).not_to eq(auth_header['HTTP_AUTHORIZATION'])

      payload, header = JWT.decode(response.token, TEST_CONFIG.secret, true, { algorithm: JWT_ALGO })
      expect(header['exp']).to be > Time.now.to_i
      expect(payload['username']).to eq('test123')
    end

    it 'should return an error if no auth header' do
      put '/api/auth'
      expect(AuthResponse.decode(last_response.body).response).to eq(:error)
    end

    it 'should return false if expired jwt' do
      put '/api/auth', {}, get_expired_auth_header
      expect(AuthResponse.decode(last_response.body).response).to eq(:error)
    end

    it 'should return false if invalid jwt' do
      put '/api/auth', {}, get_invalid_auth_header
      expect(AuthResponse.decode(last_response.body).response).to eq(:error)
    end
  end

  describe 'get /api/version' do
    it 'should return an error if no jwt' do
      get '/api/version'
      expect(VersionResponse.decode(last_response.body).response).to eq(:error)
    end

    it 'should return an error if invalid jwt' do
      get '/api/version', {}, get_invalid_auth_header
      expect(VersionResponse.decode(last_response.body).response).to eq(:error)
    end

    it 'should return an error if expired jwt' do
      get '/api/version', {}, get_expired_auth_header
      expect(VersionResponse.decode(last_response.body).response).to eq(:error)
    end

    it 'should throw an exception if the export didn\'t finish' do
      expect { get '/api/version', {}, get_auth_header }.to raise_error(ArgumentError)
    end

    it 'should return the time if the export did finish' do
      @db.exec(INSERT_EXPORT_FINISHED_SQL)

      get '/api/version', {}, get_auth_header
      version = VersionResponse.decode(last_response.body)
      expect(version.response).to eq(:updateTimeNs)
      expect(version.updateTimeNs).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end
  end

  describe 'get /api/library' do
    before :each do
      @db.exec_params('INSERT INTO library_metadata (total_file_size) VALUES ($1)', [1001])
    end

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

    it 'should return a 500 if the export did not finish' do
      expect { get '/api/library', {}, get_auth_header }.to raise_error(ArgumentError)
    end

    it 'should dump all genres, artists, albums and tracks' do
      @playlistX = 'XXXXXXXXXXXXXXXX'
      @playlist0 = '0000000000000000'
      @playlist1 = '1111111111111111'
      @playlist2 = '2222222222222222'
      @track_id3 = 'B7F8970B634DDEE3'

      @db.exec(INSERT_EXPORT_FINISHED_SQL)
      @db.exec_params('INSERT INTO playlists (id, name, is_library, parent_id) VALUES ($1,$2,$3,$4),($5,$6,$7,$8),($9,$10,$11,$12),($13,$14,$15,$16)',
                      [
                        @playlistX, 'library', 1, '',
                        @playlist0, 'test_playlist0', 0, '',
                        @playlist1, 'test_playlist1', 0, @playlist0,
                        @playlist2, 'test_playlist2', 0, ''
                      ])
      @db.exec_params('INSERT INTO playlist_tracks (playlist_id, track_id) VALUES ($1,$2),($3,$4),($5,$6)',
                      [@playlist1, @track_id3, @playlist2, @track_id2, @playlist2, @track_id])

      get '/api/library', {}, get_auth_header
      library = LibraryResponse.decode(last_response.body).library

      expect(library.genres.length).to eq(1)
      expect(library.genres[@genre_id].name).to eq('test_genre')

      expect(library.artists.length).to eq(1)
      expect(library.artists[@artist_id].name).to eq('test_artist')
      expect(library.artists[@artist_id].sortName).to eq('')

      expect(library.albums.length).to eq(1)
      library.albums.keys.first
      expect(library.albums[@album_id].name).to eq('test_album')
      expect(library.albums[@album_id].sortName).to eq('')

      expect(library.tracks.length).to eq(1)
      track = library.tracks.first
      expect(track.id).to eq(@track_id)
      expect(track.name).to eq('test_title')
      expect(track.sortName).to eq('')
      expect(track.artistId).to eq(@artist_id)
      expect(track.albumId).to eq(@album_id)
      expect(track.genreId).to eq(@genre_id)
      expect(track.year).to eq(2018)
      expect(track.duration).to be_within(0.001).of(1.23)
      expect(track.start).to be_within(0.001).of(0.1)
      expect(track.finish).to be_within(0.001).of(1.22)
      expect(track.trackNumber).to eq(2)
      expect(track.discNumber).to eq(1)
      expect(track.playCount).to eq(5)
      expect(track.rating).to eq(100)
      expect(track.ext).to eq('mp3')
      expect(track.fileMd5).to eq('06dbe92c2a5dab2f7911e20a9e157521')
      expect(track.artworkFilename.strip).to eq('__artwork.jpg')
      expect(track.playlistIds).to eq([@playlist2, @playlistX])

      expect(library.playlists.length).to eq(4)
      playlist = library.playlists[0]
      expect(playlist.id).to eq(@playlistX)
      expect(playlist.name).to eq('library')
      expect(playlist.parentId).to eq('')
      expect(playlist.isLibrary).to be(true)
      expect(playlist.trackIds).to eq([])

      playlist = library.playlists[1]
      expect(playlist.id).to eq(@playlist2)
      expect(playlist.name).to eq('test_playlist2')
      expect(playlist.parentId).to eq('')
      expect(playlist.isLibrary).to be(false)
      expect(playlist.trackIds).to eq([@track_id2, @track_id])

      playlist = library.playlists[2]
      expect(playlist.id).to eq(@playlist1)
      expect(playlist.name).to eq('test_playlist1')
      expect(playlist.parentId).to eq(@playlist0)
      expect(playlist.isLibrary).to be(false)
      expect(playlist.trackIds).to eq([@track_id3])

      playlist = library.playlists[3]
      expect(playlist.id).to eq(@playlist0)
      expect(playlist.name).to eq('test_playlist0')
      expect(playlist.parentId).to eq('')
      expect(playlist.isLibrary).to be(false)
      expect(playlist.trackIds).to eq([])

      expect(library.totalFileSize).to eq(1001)
      expect(library.updateTimeNs).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end

    it 'should include whether to track changes or not' do
      @db.exec(INSERT_EXPORT_FINISHED_SQL)
      get '/api/library', {}, get_auth_header('test123')
      library = LibraryResponse.decode(last_response.body).library
      expect(library.trackUserChanges).to be true

      get '/api/library', {}, get_auth_header('notrack')
      library = LibraryResponse.decode(last_response.body).library
      expect(library.trackUserChanges).to be false
    end

    it 'should support missing artwork' do
      @db.exec(INSERT_EXPORT_FINISHED_SQL)
      @db.exec('UPDATE tracks SET artwork_filename=NULL')
      get '/api/library', {}, get_auth_header
      library = LibraryResponse.decode(last_response.body).library
      expect(library.tracks[0].artworkFilename).to eq('')
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
      @db.exec('INSERT INTO plays (track_id) VALUES ($1);', [@track_id2])
      @db.exec('INSERT INTO plays (track_id) VALUES ($1);', [@track_id])
      @db.exec('INSERT INTO plays (track_id) VALUES ($1);', [@track_id2])

      get '/api/updates', {}, get_auth_header
      updates = UpdatesResponse.decode(last_response.body).updates
      expect(updates.plays.map(&:trackId)).to eq([@track_id2, @track_id, @track_id2])
    end

    it 'should include all ratings' do
      @db.exec('INSERT INTO rating_updates (track_id, rating) VALUES ($1, $2);', [@track_id2, 100])
      @db.exec('INSERT INTO rating_updates (track_id, rating) VALUES ($1, $2);', [@track_id, 80])
      @db.exec('INSERT INTO rating_updates (track_id, rating) VALUES ($1, $2);', [@track_id2, 60])

      get '/api/updates', {}, get_auth_header
      ratings = UpdatesResponse.decode(last_response.body).updates.ratings
      expect(ratings.map(&:trackId)).to eq([@track_id2, @track_id, @track_id2])
      expect(ratings.map(&:value)).to eq([100, 80, 60])
    end

    it 'should include all names' do
      @db.exec('INSERT INTO name_updates (track_id, name) VALUES ($1, $2);', [@track_id2, 'abc'])
      @db.exec('INSERT INTO name_updates (track_id, name) VALUES ($1, $2);', [@track_id, 'def'])
      @db.exec('INSERT INTO name_updates (track_id, name) VALUES ($1, $2);', [@track_id2, 'ghi'])

      get '/api/updates', {}, get_auth_header
      names = UpdatesResponse.decode(last_response.body).updates.names
      expect(names.map(&:trackId)).to eq([@track_id2, @track_id, @track_id2])
      expect(names.map(&:value)).to eq(%w[abc def ghi])
    end

    it 'should include all artists' do
      @db.exec('INSERT INTO artist_updates (track_id, artist) VALUES ($1, $2);', [@track_id2, 'abc'])
      @db.exec('INSERT INTO artist_updates (track_id, artist) VALUES ($1, $2);', [@track_id, 'def'])
      @db.exec('INSERT INTO artist_updates (track_id, artist) VALUES ($1, $2);', [@track_id2, 'ghi'])

      get '/api/updates', {}, get_auth_header
      artists = UpdatesResponse.decode(last_response.body).updates.artists
      expect(artists.map(&:trackId)).to eq([@track_id2, @track_id, @track_id2])
      expect(artists.map(&:value)).to eq(%w[abc def ghi])
    end

    it 'should include all albums' do
      @db.exec('INSERT INTO album_updates (track_id, album) VALUES ($1, $2);', [@track_id2, 'abc'])
      @db.exec('INSERT INTO album_updates (track_id, album) VALUES ($1, $2);', [@track_id, 'def'])
      @db.exec('INSERT INTO album_updates (track_id, album) VALUES ($1, $2);', [@track_id2, 'ghi'])

      get '/api/updates', {}, get_auth_header
      albums = UpdatesResponse.decode(last_response.body).updates.albums
      expect(albums.map(&:trackId)).to eq([@track_id2, @track_id, @track_id2])
      expect(albums.map(&:value)).to eq(%w[abc def ghi])
    end

    it 'should include all album artists' do
      @db.exec('INSERT INTO album_artist_updates (track_id, album_artist) VALUES ($1, $2);', [@track_id2, 'abc'])
      @db.exec('INSERT INTO album_artist_updates (track_id, album_artist) VALUES ($1, $2);', [@track_id, 'def'])
      @db.exec('INSERT INTO album_artist_updates (track_id, album_artist) VALUES ($1, $2);', [@track_id2, 'ghi'])

      get '/api/updates', {}, get_auth_header
      album_artists = UpdatesResponse.decode(last_response.body).updates.albumArtists
      expect(album_artists.map(&:trackId)).to eq([@track_id2, @track_id, @track_id2])
      expect(album_artists.map(&:value)).to eq(%w[abc def ghi])
    end

    it 'should include all genres' do
      @db.exec('INSERT INTO genre_updates (track_id, genre) VALUES ($1, $2);', [@track_id2, 'abc'])
      @db.exec('INSERT INTO genre_updates (track_id, genre) VALUES ($1, $2);', [@track_id, 'def'])
      @db.exec('INSERT INTO genre_updates (track_id, genre) VALUES ($1, $2);', [@track_id2, 'ghi'])

      get '/api/updates', {}, get_auth_header
      genres = UpdatesResponse.decode(last_response.body).updates.genres
      expect(genres.map(&:trackId)).to eq([@track_id2, @track_id, @track_id2])
      expect(genres.map(&:value)).to eq(%w[abc def ghi])
    end

    it 'should include all years' do
      @db.exec('INSERT INTO year_updates (track_id, year) VALUES ($1, $2);', [@track_id2, 100])
      @db.exec('INSERT INTO year_updates (track_id, year) VALUES ($1, $2);', [@track_id, 200])
      @db.exec('INSERT INTO year_updates (track_id, year) VALUES ($1, $2);', [@track_id2, 300])

      get '/api/updates', {}, get_auth_header
      years = UpdatesResponse.decode(last_response.body).updates.years
      expect(years.map(&:trackId)).to eq([@track_id2, @track_id, @track_id2])
      expect(years.map(&:value)).to eq([100, 200, 300])
    end

    it 'should include all starts' do
      @db.exec('INSERT INTO start_updates (track_id, start) VALUES ($1, $2);', [@track_id2, 1.1])
      @db.exec('INSERT INTO start_updates (track_id, start) VALUES ($1, $2);', [@track_id, 1.2])
      @db.exec('INSERT INTO start_updates (track_id, start) VALUES ($1, $2);', [@track_id2, 1.3])

      get '/api/updates', {}, get_auth_header
      starts = UpdatesResponse.decode(last_response.body).updates.starts
      expect(starts.map(&:trackId)).to eq([@track_id2, @track_id, @track_id2])
      expect(starts[0].value).to be_within(0.001).of(1.1)
      expect(starts[1].value).to be_within(0.001).of(1.2)
      expect(starts[2].value).to be_within(0.001).of(1.3)
    end

    it 'should include all finishes' do
      @db.exec('INSERT INTO finish_updates (track_id, finish) VALUES ($1, $2);', [@track_id2, 1.1])
      @db.exec('INSERT INTO finish_updates (track_id, finish) VALUES ($1, $2);', [@track_id, 1.2])
      @db.exec('INSERT INTO finish_updates (track_id, finish) VALUES ($1, $2);', [@track_id2, 1.3])

      get '/api/updates', {}, get_auth_header
      finishes = UpdatesResponse.decode(last_response.body).updates.finishes
      expect(finishes.map(&:trackId)).to eq([@track_id2, @track_id, @track_id2])
      expect(finishes[0].value).to be_within(0.001).of(1.1)
      expect(finishes[1].value).to be_within(0.001).of(1.2)
      expect(finishes[2].value).to be_within(0.001).of(1.3)
    end

    it 'should include all artwork updates' do
      @db.exec('INSERT INTO artwork_updates (track_id, artwork_filename) VALUES ($1, $2);', [@track_id2, 'hi.jpg'])
      @db.exec('INSERT INTO artwork_updates (track_id, artwork_filename) VALUES ($1, $2);', [@track_id, nil])
      @db.exec('INSERT INTO artwork_updates (track_id, artwork_filename) VALUES ($1, $2);', [@track_id2, 'hello.png'])

      get '/api/updates', {}, get_auth_header
      artworks = UpdatesResponse.decode(last_response.body).updates.artworks
      expect(artworks.map(&:trackId)).to eq([@track_id2, @track_id, @track_id2])
      expect(artworks[0].value.strip).to eq('hi.jpg')
      expect(artworks[1].value).to eq('')
      expect(artworks[2].value.strip).to eq('hello.png')
    end
  end

  describe '/api/play/*' do
    it 'should return an error if no jwt' do
      post "/api/play/#{@track_id}"
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'should return an error if invalid jwt' do
      post "/api/play/#{@track_id}", {}, get_invalid_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'should return an error if expired jwt' do
      post "/api/play/#{@track_id}", {}, get_expired_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'should return an error if not tracking the user\'s changes' do
      post "/api/play/#{@track_id}", {}, get_auth_header('notrack')
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
      insert_old_export_finished_at
      expect(get_first_value("SELECT play_count FROM tracks WHERE id='#{@track_id}'")).to eq('5')

      post "/api/play/#{@track_id}", {}, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM plays')).to eq('1')
      expect(get_first_value('SELECT track_id FROM plays')).to eq(@track_id)
      expect(get_first_value("SELECT play_count FROM tracks WHERE id='#{@track_id}'")).to eq('6')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end
  end

  describe '/api/rating/*' do
    it 'should return an error if rating is missing' do
      post "/api/rating/#{@track_id}", {}, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_RATING_ERROR)
    end

    it 'should return an error if rating is non-numeric' do
      post "/api/rating/#{@track_id}", { rating: 'abcd' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_RATING_ERROR)
    end

    it 'should return an error if rating is empty' do
      post "/api/rating/#{@track_id}", { rating: '' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_RATING_ERROR)
    end

    it 'should return an error if rating is too high' do
      post "/api/rating/#{@track_id}", { rating: '120' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_RATING_ERROR)
    end

    it 'should return an error if rating is too low' do
      post "/api/rating/#{@track_id}", { rating: '-1' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_RATING_ERROR)
    end

    it 'should return an error if no jwt' do
      post "/api/rating/#{@track_id}", { rating: '80' }
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'should return an error if invalid jwt' do
      post "/api/rating/#{@track_id}", { rating: '80' }, get_invalid_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'should return an error if expired jwt' do
      post "/api/rating/#{@track_id}", { rating: '80' }, get_expired_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'should return an error if not tracking the user\'s changes' do
      post "/api/rating/#{@track_id}", { rating: '80' }, get_auth_header('notrack')
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
      insert_old_export_finished_at
      expect(get_first_value("SELECT rating FROM tracks WHERE id='#{@track_id}'")).to eq('100')

      post "/api/rating/#{@track_id}", { rating: '80' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM rating_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM rating_updates')).to eq(@track_id)
      expect(get_first_value('SELECT rating FROM rating_updates')).to eq('80')
      expect(get_first_value("SELECT rating FROM tracks WHERE id='#{@track_id}'")).to eq('80')

      post "/api/rating/#{@track_id}", { rating: '100' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM rating_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM rating_updates')).to eq(@track_id)
      expect(get_first_value('SELECT rating FROM rating_updates')).to eq('100')
      expect(get_first_value("SELECT rating FROM tracks WHERE id='#{@track_id}'")).to eq('100')

      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end
  end

  describe '/api/track-info/*' do
    before do
      insert_old_export_finished_at
    end

    it 'should return an error if no jwt' do
      post "/api/track-info/#{@track_id}"
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'should return an error if invalid jwt' do
      post "/api/track-info/#{@track_id}", {}, get_invalid_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'should return an error if expired jwt' do
      post "/api/track-info/#{@track_id}", {}, get_expired_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'should return an error if not tracking the user\'s changes' do
      post "/api/track-info/#{@track_id}", {}, get_auth_header('notrack')
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

    it 'should return an error if artwork file does not exist' do
      post '/api/track-info/ABCD', { artwork: 'abcd.png' }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(MISSING_FILE_ERROR)
    end

    it 'should create a name update if tracking this user\'s changes is enabled' do
      expect(get_first_value("SELECT name FROM tracks WHERE id='#{@track_id}'")).to eq('test_title')

      post "/api/track-info/#{@track_id}", { name: 'abc' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM name_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM name_updates')).to eq(@track_id)
      expect(get_first_value('SELECT name FROM name_updates')).to eq('abc')
      expect(get_first_value("SELECT name FROM tracks WHERE id='#{@track_id}'")).to eq('abc')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)

      post "/api/track-info/#{@track_id}", { name: 'test_title' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM name_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM name_updates')).to eq(@track_id)
      expect(get_first_value('SELECT name FROM name_updates')).to eq('test_title')
      expect(get_first_value("SELECT name FROM tracks WHERE id='#{@track_id}'")).to eq('test_title')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end

    it 'should create a year update if tracking this user\'s changes is enabled' do
      expect(get_first_value("SELECT year FROM tracks WHERE id='#{@track_id}'")).to eq('2018')

      post "/api/track-info/#{@track_id}", { year: '1970' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM year_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM year_updates')).to eq(@track_id)
      expect(get_first_value('SELECT year FROM year_updates')).to eq('1970')
      expect(get_first_value("SELECT year FROM tracks WHERE id='#{@track_id}'")).to eq('1970')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)

      post "/api/track-info/#{@track_id}", { year: '1990' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM year_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM year_updates')).to eq(@track_id)
      expect(get_first_value('SELECT year FROM year_updates')).to eq('1990')
      expect(get_first_value("SELECT year FROM tracks WHERE id='#{@track_id}'")).to eq('1990')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end

    it 'should create a start update if tracking this user\'s changes is enabled' do
      expect(get_first_value("SELECT start FROM tracks WHERE id='#{@track_id}'")).to eq('0.1')

      post "/api/track-info/#{@track_id}", { start: '1.2' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM start_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM start_updates')).to eq(@track_id)
      expect(get_first_value('SELECT start FROM start_updates')).to eq('1.2')
      expect(get_first_value("SELECT start FROM tracks WHERE id='#{@track_id}'")).to eq('1.2')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)

      post "/api/track-info/#{@track_id}", { start: '1.3' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM start_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM start_updates')).to eq(@track_id)
      expect(get_first_value('SELECT start FROM start_updates')).to eq('1.3')
      expect(get_first_value("SELECT start FROM tracks WHERE id='#{@track_id}'")).to eq('1.3')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end

    it 'should create a finish update if tracking this user\'s changes is enabled' do
      expect(get_first_value("SELECT finish FROM tracks WHERE id='#{@track_id}'")).to eq('1.22')

      post "/api/track-info/#{@track_id}", { finish: '2.3' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM finish_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM finish_updates')).to eq(@track_id)
      expect(get_first_value('SELECT finish FROM finish_updates')).to eq('2.3')
      expect(get_first_value("SELECT finish FROM tracks WHERE id='#{@track_id}'")).to eq('2.3')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)

      post "/api/track-info/#{@track_id}", { finish: '2.4' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM finish_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM finish_updates')).to eq(@track_id)
      expect(get_first_value('SELECT finish FROM finish_updates')).to eq('2.4')
      expect(get_first_value("SELECT finish FROM tracks WHERE id='#{@track_id}'")).to eq('2.4')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end

    it 'should create an artist update if tracking this user\'s changes is enabled' do
      expect(get_first_value("SELECT artists.name FROM tracks JOIN artists ON tracks.artist_id = artists.id WHERE tracks.id='#{@track_id}'")).to eq('test_artist')
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('1')

      post "/api/track-info/#{@track_id}", { artist: 'new_artist' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM artist_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM artist_updates')).to eq(@track_id)
      expect(get_first_value('SELECT artist FROM artist_updates')).to eq('new_artist')
      expect(get_first_value("SELECT artists.name FROM tracks JOIN artists ON tracks.artist_id = artists.id WHERE tracks.id='#{@track_id}'")).to eq('new_artist')
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('2')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)

      post "/api/track-info/#{@track_id}", { artist: 'test_artist' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM artist_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM artist_updates')).to eq(@track_id)
      expect(get_first_value('SELECT artist FROM artist_updates')).to eq('test_artist')
      expect(get_first_value("SELECT artists.name FROM tracks JOIN artists ON tracks.artist_id = artists.id WHERE tracks.id='#{@track_id}'")).to eq('test_artist')
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('2')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end

    it 'should create an genre update if tracking this user\'s changes is enabled' do
      expect(get_first_value("SELECT genres.name FROM tracks JOIN genres ON tracks.genre_id = genres.id WHERE tracks.id='#{@track_id}'")).to eq('test_genre')
      expect(get_first_value('SELECT COUNT(*) FROM genres')).to eq('1')

      post "/api/track-info/#{@track_id}", { genre: 'new_genre' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM genre_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM genre_updates')).to eq(@track_id)
      expect(get_first_value('SELECT genre FROM genre_updates')).to eq('new_genre')
      expect(get_first_value("SELECT genres.name FROM tracks JOIN genres ON tracks.genre_id = genres.id WHERE tracks.id='#{@track_id}'")).to eq('new_genre')
      expect(get_first_value('SELECT COUNT(*) FROM genres')).to eq('2')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)

      post "/api/track-info/#{@track_id}", { genre: 'test_genre' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM genre_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM genre_updates')).to eq(@track_id)
      expect(get_first_value('SELECT genre FROM genre_updates')).to eq('test_genre')
      expect(get_first_value("SELECT genres.name FROM tracks JOIN genres ON tracks.genre_id = genres.id WHERE tracks.id='#{@track_id}'")).to eq('test_genre')
      expect(get_first_value('SELECT COUNT(*) FROM genres')).to eq('2')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end

    it 'should create an album artist update if tracking this user\'s changes is enabled' do
      expect(get_first_value("SELECT album_artist_id FROM tracks WHERE tracks.id='#{@track_id}'")).to eq(nil)
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('1')

      post "/api/track-info/#{@track_id}", { album_artist: 'new_album_artist' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM album_artist_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_artist_updates')).to eq(@track_id)
      expect(get_first_value('SELECT album_artist FROM album_artist_updates')).to eq('new_album_artist')
      expect(get_first_value("SELECT artists.name FROM tracks JOIN artists ON tracks.album_artist_id = artists.id WHERE tracks.id='#{@track_id}'")).to eq('new_album_artist')
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('2')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)

      post "/api/track-info/#{@track_id}", { album_artist: '' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM album_artist_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_artist_updates')).to eq(@track_id)
      expect(get_first_value('SELECT album_artist FROM album_artist_updates')).to eq('')
      expect(get_first_value("SELECT album_artist_id FROM tracks WHERE id='#{@track_id}'")).to eq(nil)
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('2')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)

      post "/api/track-info/#{@track_id}", { album_artist: 'test_artist' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM album_artist_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_artist_updates')).to eq(@track_id)
      expect(get_first_value('SELECT album_artist FROM album_artist_updates')).to eq('test_artist')
      expect(get_first_value("SELECT artists.name FROM tracks JOIN artists ON tracks.album_artist_id = artists.id WHERE tracks.id='#{@track_id}'")).to eq('test_artist')
      expect(get_first_value('SELECT COUNT(*) FROM artists')).to eq('2')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end

    it 'should create an album update if tracking this user\'s changes is enabled' do
      expect(get_first_value("SELECT albums.name FROM tracks JOIN albums ON tracks.album_id = albums.id WHERE tracks.id='#{@track_id}'")).to eq('test_album')
      expect(get_first_value('SELECT COUNT(*) FROM albums')).to eq('1')

      post "/api/track-info/#{@track_id}", { album: 'new_album' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM album_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_updates')).to eq(@track_id)
      expect(get_first_value('SELECT album FROM album_updates')).to eq('new_album')
      expect(get_first_value("SELECT albums.name FROM tracks JOIN albums ON tracks.album_id = albums.id WHERE tracks.id='#{@track_id}'")).to eq('new_album')
      expect(get_first_value('SELECT COUNT(*) FROM albums')).to eq('2')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)

      post "/api/track-info/#{@track_id}", { album: '' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM album_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_updates')).to eq(@track_id)
      expect(get_first_value('SELECT album FROM album_updates')).to eq('')
      expect(get_first_value("SELECT album_id FROM tracks WHERE id='#{@track_id}'")).to eq(nil)
      expect(get_first_value('SELECT COUNT(*) FROM albums')).to eq('2')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)

      post "/api/track-info/#{@track_id}", { album: 'test_album' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM album_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM album_updates')).to eq(@track_id)
      expect(get_first_value('SELECT album FROM album_updates')).to eq('test_album')
      expect(get_first_value("SELECT albums.name FROM tracks JOIN albums ON tracks.album_id = albums.id WHERE tracks.id='#{@track_id}'")).to eq('test_album')
      expect(get_first_value('SELECT COUNT(*) FROM albums')).to eq('2')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end

    it 'should create an artwork update if tracking this user\'s changes' do
      expect(get_first_value("SELECT artwork_filename FROM tracks WHERE id='#{@track_id}'").strip).to eq('__artwork.jpg')

      post "/api/track-info/#{@track_id}", { artwork: '__artwork.png' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM artwork_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM artwork_updates')).to eq(@track_id)
      expect(get_first_value('SELECT artwork_filename FROM artwork_updates').strip).to eq('__artwork.png')
      expect(get_first_value("SELECT artwork_filename FROM tracks WHERE id='#{@track_id}'").strip).to eq('__artwork.png')
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)

      post "/api/track-info/#{@track_id}", { artwork: '' }, get_auth_header
      expect(OperationResponse.decode(last_response.body).success).to be true
      expect(get_first_value('SELECT COUNT(*) FROM artwork_updates')).to eq('1')
      expect(get_first_value('SELECT track_id FROM artwork_updates')).to eq(@track_id)
      expect(get_first_value('SELECT artwork_filename FROM artwork_updates')).to eq(nil)
      expect(get_first_value("SELECT artwork_filename FROM tracks WHERE id='#{@track_id}'")).to eq(nil)
      expect(export_finished_at).to be_within(2E9).of(Time.now.to_i * 1_000_000_000)
    end
  end

  describe '/api/artwork' do
    after :each do
      FileUtils.rm_f('spec/27a8d4658b73d9533c1db34ee2350da0.jpg')
      FileUtils.rm_f('spec/f693282ce0329b1fb9ec383feae8088b.png')
    end

    it 'should return an error if no jwt' do
      post '/api/artwork', 'file' => Rack::Test::UploadedFile.new('spec/__artwork.jpg', 'image/jpeg')
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'should return an error if invalid jwt' do
      post '/api/artwork', {}, get_invalid_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'should return an error if expired jwt' do
      post '/api/artwork', {}, get_expired_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_AUTHED_ERROR)
    end

    it 'should return an error if not tracking the user\'s changes' do
      post '/api/artwork', {}, get_auth_header('notrack')
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(NOT_TRACKING_ERROR)
    end

    it 'should return an error if missing the file' do
      post '/api/artwork', {}, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(MISSING_FILE_ERROR)
    end

    it 'should return an error if an invalid extension' do
      invalid_ext_uploaded_file = Rack::Test::UploadedFile.new('spec/__artwork.jpg', 'image/wav', true, original_filename: 'artwork.wav')
      post '/api/artwork', { 'file' => invalid_ext_uploaded_file }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_MIME_ERROR)
    end

    it 'should return an error if the md5 doesn\'t match the filename' do
      invalid_md5_uploaded_file = Rack::Test::UploadedFile.new('spec/__artwork.jpg', 'image/jpeg', true, original_filename: '49f68a5c8493ec2c0bf489821c21fc3b.jpg')
      post '/api/artwork', { 'file' => invalid_md5_uploaded_file }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be false
      expect(resp.error).to eq(INVALID_MD5_ERROR)
    end

    it 'should accept a valid jpg' do
      expect(File.exist?('spec/27a8d4658b73d9533c1db34ee2350da0.jpg')).to be false
      jpg_uploaded_file = Rack::Test::UploadedFile.new('spec/__artwork.jpg', 'image/jpeg', true, original_filename: '27a8d4658b73d9533c1db34ee2350da0.jpg')
      post '/api/artwork', { 'file' => jpg_uploaded_file }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be true
      expect(File.read('spec/27a8d4658b73d9533c1db34ee2350da0.jpg')).to eq("fake jpg contents\n")
    end

    it 'should accept a valid png' do
      expect(File.exist?('spec/f693282ce0329b1fb9ec383feae8088b.png')).to be false
      png_uploaded_file = Rack::Test::UploadedFile.new('spec/__artwork.png', 'image/png', true, original_filename: 'f693282ce0329b1fb9ec383feae8088b.png')
      post '/api/artwork', { 'file' => png_uploaded_file }, get_auth_header
      resp = OperationResponse.decode(last_response.body)
      expect(resp.success).to be true
      expect(File.read('spec/f693282ce0329b1fb9ec383feae8088b.png')).to eq("fake png contents\n")
    end
  end
end
