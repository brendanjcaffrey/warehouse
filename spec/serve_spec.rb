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
                       'track_plays' => true },
        'notrack' => { 'password' => 'notrack',
                       'track_plays' => false }
      }
    }
  end
end
require_relative '../serve'

describe 'iTunes Streamer' do
  include Rack::Test::Methods

  def app
    Serve
  end

  before :all do
    @db = PG.connect(user: Config['database_username'], dbname: Config['database_name'])
  end

  before :each do
    @db.exec('DELETE FROM plays')
    @db.exec('DELETE FROM users')
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
      expect(last_response.body).to include('[3,4,5]')
    end
  end

  describe '/tracks/*' do
    it 'should redirect if not logged in' do
      get '/tracks/1'
      follow_redirect!
      expect(last_request.url).to eq('http://example.org/')
    end

    it 'should 404 if the track doesn\'t exist in the database' do
      get '/tracks/2', {}, fake_auth('test123')
      expect(last_response.status).to eq(404)
    end

    it 'should send the contents of the file' do
      get '/tracks/1', {}, fake_auth('test123')
      expect(last_response.body).to eq("1.mp3 contents\n")
    end
  end

  describe '/download/*' do
    it 'should redirect if not logged in' do
      get '/download/1'
      follow_redirect!
      expect(last_request.url).to eq('http://example.org/')
    end

    it 'should 404 if the track doesn\'t exist in the database' do
      get '/download/2', {}, fake_auth('test123')
      expect(last_response.status).to eq(404)
    end

    it 'should send the contents of the file with a header' do
      get '/download/1', {}, fake_auth('test123')
      expect(last_response.body).to eq("1.mp3 contents\n")
      expect(last_response.headers['Content-Disposition']).to include('attachment')
      expect(last_response.headers['Content-Disposition']).to include('filename="test_title.mp3"')
    end
  end

  describe 'plays.json' do
    it 'should dump all plays' do
      @db.exec('INSERT INTO plays (track_id) VALUES (1)')
      @db.exec('INSERT INTO plays (track_id) VALUES (2)')
      @db.exec('INSERT INTO plays (track_id) VALUES (1)')

      get '/plays.json'
      expect(last_response.body).to eq('[1,2,1]')
    end
  end

  describe '/play/*' do
    it 'should redirect if not logged in' do
      post '/play/1'
      follow_redirect!
      expect(last_request.url).to eq('http://example.org/')
    end

    it 'should 404 if the track doesn\'t exist in the database' do
      post '/play/2', {}, fake_auth('test123')
      expect(last_response.status).to eq(404)
    end

    it 'should create a play if tracking this user\'s play is enabled' do
      post '/play/1', {}, fake_auth('test123')
      expect(get_first_value('SELECT COUNT(*) FROM plays')).to eq('1')
    end

    it 'should create a play if tracking this user\'s play is enabled' do
      post '/play/1', {}, fake_auth('notrack')
      expect(get_first_value('SELECT COUNT(*) FROM plays')).to eq('0')
    end
  end
end
