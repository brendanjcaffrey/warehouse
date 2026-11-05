require 'rspec'
require 'pg'
require 'json'
require 'yaml'
require 'uri'
require 'date'
require 'tmpdir'
require 'fileutils'
require 'securerandom'
require 'open3'

RSpec.describe 'daily database archives' do
  let(:tracks) { JSON.parse(File.read(File.join(__dir__, 'fixtures/tracks.json'))) }
  let(:playlists) { JSON.parse(File.read(File.join(__dir__, 'fixtures/playlists.json'))) }
  let(:credentials) do
    ENV['CI'] ? { 'database_username' => 'ci', 'database_password' => 'ci' } : YAML.safe_load_file('config.yaml').fetch('local')
  end
  let(:directory) { Dir.mktmpdir('warehouse-archive') }
  let(:schema) { "changes_test_#{SecureRandom.hex(8)}" }
  let(:database_url) do
    "postgresql://localhost/warehouse_test?#{URI.encode_www_form(user: credentials.fetch('database_username'), password: credentials['database_password'].to_s, options: "-csearch_path=#{schema}")}"
  end
  let(:db) { PG.connect(database_url) }

  around do |example|
    connection = db
    connection.set_notice_receiver { |_notice| nil }
    begin
      %w[tracks playlists].each { |type| FileUtils.mkdir_p(File.join(directory, type)) }
      db.exec("CREATE SCHEMA #{schema}")
      db.exec(File.read(File.expand_path('../../export/export/CreateTables.sql', __dir__)))
      seed_database
      example.run
    ensure
      connection.exec("DROP SCHEMA IF EXISTS #{schema} CASCADE")
      connection.close
      FileUtils.remove_entry(directory)
    end
  end

  def seed_database
    db.exec_params('INSERT INTO artists VALUES (1, $1, $1)', [tracks.first.fetch('artist')])
    db.exec_params('INSERT INTO albums VALUES (1, $1, $1)', [tracks.first.fetch('album')])
    db.exec_params('INSERT INTO genres VALUES (1, $1)', [tracks.first.fetch('genre')])
    tracks.each do |track|
      row = track.except('artist', 'album_artist', 'album', 'genre').merge('artist_id' => 1, 'album_artist_id' => 1, 'album_id' => 1, 'genre_id' => 1)
      params = row.keys.each_index.map { |index| "$#{index + 1}" }.join(', ')
      db.exec_params("INSERT INTO tracks (#{row.keys.join(', ')}) VALUES (#{params})", row.values)
    end
    playlists.each do |playlist|
      db.exec_params('INSERT INTO playlists VALUES ($1, $2, 0, $3)', playlist.values_at('id', 'name', 'parent_id'))
      playlist.fetch('tracks').each do |track_id|
        db.exec_params('INSERT INTO playlist_tracks VALUES ($1, $2)', [playlist.fetch('id'), track_id])
      end
    end
    db.exec("INSERT INTO playlists VALUES ('0000000000000099', 'library', 1, NULL)")
    db.exec('INSERT INTO export_finished VALUES (current_timestamp)')
  end

  def snapshot_path(type)
    File.join(directory, type, "#{Date.today.strftime('%Y%m%d')}.json")
  end

  def archive
    Open3.capture3({ 'CHANGES_DATABASE_URL' => database_url, 'CHANGES_DIRECTORY' => directory },
                   'bundle', 'exec', 'rake', 'changes:archive', chdir: File.expand_path('../..', __dir__))
  end

  it 'archives exact multiline text and existing track and playlist metadata through rake' do
    stdout, stderr, status = archive

    expect(status).to be_success, stderr
    expect(stdout + stderr).not_to include('LYRIC_SENTINEL')
    archived = JSON.parse(File.read(snapshot_path('tracks')))
    expect(archived).to eq(tracks)
    %w[lyrics comments].each do |field|
      expect(archived.map { |track| track.fetch(field).bytes }).to eq(tracks.map { |track| track.fetch(field).bytes })
    end
    expect(JSON.parse(File.read(snapshot_path('playlists')))).to eq(playlists)
  end

  it 'does not replace existing snapshots when the export is unfinished' do
    db.exec('DELETE FROM export_finished')
    %w[tracks playlists].each do |type|
      FileUtils.mkdir_p(File.dirname(snapshot_path(type)))
      File.write(snapshot_path(type), 'existing snapshot')
    end

    stdout, _stderr, status = archive

    expect(status).not_to be_success
    expect(stdout).to include('export did not finish!')
    %w[tracks playlists].each { |type| expect(File.read(snapshot_path(type))).to eq('existing snapshot') }
  end

  it 'archives an empty library as json arrays usable by the diff' do
    %w[playlist_tracks playlists tracks artists albums genres].each { |table| db.exec("DELETE FROM #{table}") }

    _stdout, stderr, status = archive

    expect(status).to be_success, stderr
    %w[tracks playlists].each { |type| expect(JSON.parse(File.read(snapshot_path(type)))).to eq([]) }
  end
end
