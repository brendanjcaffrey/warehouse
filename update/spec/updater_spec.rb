require 'rspec'
require_relative '../../shared/config'
require_relative '../database'
require_relative '../library'
require_relative '../updater'

RSpec.describe 'queued music updates' do
  subject(:updater) { Update::Updater.new(database, library) }

  let(:database) { instance_double(Update::Database) }
  let(:library) { Update::Library.new }
  let(:command) { instance_double(TTY::Command) }
  let(:local_config) { LocalConfig.new(update_library: true, artwork_path: '/unused') }
  let(:remote_config) { RemoteConfig.new(update_library: true, base_url: 'https://warehouse.invalid', secret: 'test-secret') }
  let(:track_id) { '0123456789ABCDEF' }
  let(:other_id) { 'FEDCBA9876543210' }
  let(:text) { "\uFEFFcafe\u0301 雪 🎵\r\nO'Brien \"quoted\" \\path \\n\n\n" }
  let(:remote_updates) { Updates.new }
  let(:writes) { [] }
  let(:tracks) { Hash.new { |hash, id| hash[id] = { 'lyrics' => 'original lyrics', 'comments' => 'original comments' } } }
  let(:http) { instance_double(Net::HTTP) }
  let(:response) { Net::HTTPOK.new('1.1', '200', 'OK') }

  before do
    allow(Config).to receive_messages(local: local_config, remote: remote_config)
    allow(TTY::Command).to receive(:new).and_return(command)
    allow(command).to receive(:run) do |*args|
      raise 'unexpected music execution' unless args.size == 6 && args.take(4) == ['osascript', '-l', 'JavaScript', '-e']

      script, path = args.last(2)
      request = JSON.parse(File.read(path))
      field = script.include?('track.lyrics = request.value') ? 'lyrics' : 'comments'
      tracks[request['track_id']][field] = request['value']
      writes << [field, request['track_id'], request['value']]
      instance_double(TTY::Command::Result, out: "#{JSON.generate(tracks[request['track_id']][field])}\n")
    end
    allow(database).to receive_messages(get_plays: [], get_ratings: [], get_name_updates: [], get_artist_updates: [],
                                        get_album_updates: [], get_album_artist_updates: [], get_genre_updates: [],
                                        get_year_updates: [], get_start_updates: [], get_finish_updates: [],
                                        get_artwork_updates: [], get_lyrics_updates: [], get_comments_updates: [],
                                        get_track_and_artist_name: %w[track artist])
    allow(Net::HTTP).to receive(:start).with('warehouse.invalid', 443, use_ssl: true).and_yield(http)
    allow(http).to receive(:request).and_return(response)
    allow(response).to receive(:body) { UpdatesResponse.encode(UpdatesResponse.new(updates: remote_updates)) }
    allow($stdout).to receive(:puts)
  end

  %w[lyrics comments].each do |field|
    other_field = field == 'lyrics' ? 'comments' : 'lyrics'

    it "applies local #{field} without changing #{other_field} or other tracks" do
      remote_config.update_library = false
      allow(database).to receive("get_#{field}_updates").and_return([[track_id, text], [other_id, '']])

      updater.update_library!

      expect(writes).to eq([[field, track_id, text], [field, other_id, '']])
      expect(tracks[track_id]).to eq(field => text, other_field => "original #{other_field}")
      expect(tracks[other_id]).to eq(field => '', other_field => "original #{other_field}")
      expect(http).not_to have_received(:request)
      expect($stdout).to have_received(:puts).with("\n=== #{field.capitalize} ===").once
    end

    it "applies remote #{field} without changing #{other_field} or consulting local queues" do
      local_config.update_library = false
      remote_updates.public_send(field).push(StringUpdate.new(trackId: track_id, value: text), StringUpdate.new(trackId: other_id, value: ''))

      updater.update_library!

      expect(writes).to eq([[field, track_id, text], [field, other_id, '']])
      expect(tracks[track_id]).to eq(field => text, other_field => "original #{other_field}")
      expect(tracks[other_id]).to eq(field => '', other_field => "original #{other_field}")
      expect(database).not_to have_received(:get_plays)
      expect(database).not_to have_received(:get_lyrics_updates)
      expect(database).not_to have_received(:get_comments_updates)
      expect($stdout).to have_received(:puts).with("\n=== #{field.capitalize} ===").once
    end
  end

  it 'finishes local updates before fetching remote ones and lets remote whole-field values win' do
    allow(database).to receive_messages(get_lyrics_updates: [[track_id, text]], get_comments_updates: [[track_id, 'local comments']])
    remote_updates.lyrics.push(StringUpdate.new(trackId: track_id, value: ''))
    remote_updates.comments.push(StringUpdate.new(trackId: track_id, value: text))
    allow(http).to receive(:request) do
      expect(writes).to eq([['lyrics', track_id, text], ['comments', track_id, 'local comments']])
      response
    end

    updater.update_library!

    expect(writes).to eq([['lyrics', track_id, text], ['comments', track_id, 'local comments'], ['lyrics', track_id, ''], ['comments', track_id, text]])
    expect(tracks[track_id]).to eq('lyrics' => '', 'comments' => text)
  end

  it 'preserves a local field when the remote update only supplies the other field' do
    allow(database).to receive(:get_lyrics_updates).and_return([[track_id, text]])
    remote_updates.comments.push(StringUpdate.new(trackId: track_id, value: ''))

    updater.update_library!

    expect(tracks[track_id]).to eq('lyrics' => text, 'comments' => '')
  end

  it 'does no work when both update sources are disabled' do
    local_config.update_library = remote_config.update_library = false

    updater.update_library!

    expect(database).not_to have_received(:get_plays)
    expect(http).not_to have_received(:request)
    expect(command).not_to have_received(:run)
  end

  it 'uses the existing authenticated update endpoint' do
    updater.update_library!

    expect(http).to have_received(:request) do |request|
      expect(request).to be_a(Net::HTTP::Get)
      expect(request.path).to eq('/api/updates')
      expect(decode_jwt(request['Authorization'].delete_prefix('Bearer '), remote_config.secret).first['username']).to eq('export_driver_update_library')
    end
  end

  it 'accepts old remote responses without text updates and leaves existing text alone' do
    updater.update_library!

    expect(writes).to be_empty
    expect(tracks[track_id]).to eq('lyrics' => 'original lyrics', 'comments' => 'original comments')
  end

  it 'continues applying unrelated metadata from both sources' do
    allow(database).to receive_messages(get_plays: [track_id], get_ratings: [[track_id, '60']], get_name_updates: [[track_id, 'local name']],
                                        get_artist_updates: [[track_id, 'local artist']], get_album_updates: [[track_id, 'local album']],
                                        get_album_artist_updates: [[track_id, 'local album artist']], get_genre_updates: [[track_id, 'local genre']],
                                        get_year_updates: [[track_id, '2001']], get_start_updates: [[track_id, '1.5']],
                                        get_finish_updates: [[track_id, '120.5']], get_artwork_updates: [[track_id, '']])
    remote_updates.plays.push(IncrementUpdate.new(trackId: track_id))
    remote_updates.ratings.push(IntUpdate.new(trackId: track_id, value: 80))
    remote_updates.names.push(StringUpdate.new(trackId: track_id, value: 'remote name'))
    remote_updates.artists.push(StringUpdate.new(trackId: track_id, value: 'remote artist'))
    remote_updates.albums.push(StringUpdate.new(trackId: track_id, value: 'remote album'))
    remote_updates.albumArtists.push(StringUpdate.new(trackId: track_id, value: 'remote album artist'))
    remote_updates.genres.push(StringUpdate.new(trackId: track_id, value: 'remote genre'))
    remote_updates.years.push(IntUpdate.new(trackId: track_id, value: 2002))
    remote_updates.starts.push(FloatUpdate.new(trackId: track_id, value: 2.5))
    remote_updates.finishes.push(FloatUpdate.new(trackId: track_id, value: 121.5))
    remote_updates.artworks.push(StringUpdate.new(trackId: track_id, value: ''))
    %i[add_play update_rating update_name update_artist update_album update_album_artist update_genre update_year update_start update_finish update_artwork].each do |method|
      allow(library).to receive(method)
    end

    allow(File).to receive(:exist?).with('/unused/').and_return(true)

    updater.update_library!

    expect(library).to have_received(:add_play).with(track_id).twice
    { rating: ['60', 80], name: ['local name', 'remote name'], artist: ['local artist', 'remote artist'],
      album: ['local album', 'remote album'], album_artist: ['local album artist', 'remote album artist'],
      genre: ['local genre', 'remote genre'], year: ['2001', 2002], start: ['1.5', 2.5], finish: ['120.5', 121.5] }.each do |field, values|
      values.each { |value| expect(library).to have_received("update_#{field}").with(track_id, value) }
    end
    expect(library).to have_received(:update_artwork).with(track_id, '').twice
  end

  it 'propagates local automation failures before fetching remote updates' do
    allow(database).to receive(:get_lyrics_updates).and_return([[track_id, text]])
    allow(command).to receive(:run).and_raise('automation denied')

    expect { updater.update_library! }.to raise_error('automation denied')
    expect(http).not_to have_received(:request)
  end
end
