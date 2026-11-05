require 'rspec'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'open3'

RSpec.describe 'archive diff output' do
  let(:tracks) { JSON.parse(File.read(File.join(__dir__, 'fixtures/tracks.json'))) }
  let(:playlists) { JSON.parse(File.read(File.join(__dir__, 'fixtures/playlists.json'))) }
  let(:old_tracks) { tracks.map(&:dup) }
  let(:new_tracks) { tracks.map(&:dup) }
  let(:old_playlists) { playlists.map(&:dup) }
  let(:new_playlists) { playlists.map(&:dup) }

  def diff(rake: false)
    Dir.mktmpdir('warehouse-diff') do |directory|
      %w[tracks playlists].each { |name| FileUtils.mkdir_p(File.join(directory, name)) }
      { '20000101' => [old_tracks, old_playlists], '20000102' => [new_tracks, new_playlists] }.each do |date, (track_data, playlist_data)|
        File.write(File.join(directory, 'tracks', "#{date}.json"), JSON.generate(track_data))
        File.write(File.join(directory, 'playlists', "#{date}.json"), JSON.generate(playlist_data))
      end
      args = rake ? ['bundle', 'exec', 'rake', 'changes:diff'] : [RbConfig.ruby, File.expand_path('../diff.rb', __dir__)]
      stdout, stderr, status = Open3.capture3({ 'CHANGES_DIRECTORY' => directory }, *args, chdir: File.expand_path('../..', __dir__))
      expect(status).to be_success, stderr
      expect(stdout).not_to include('Aborting')
      expect(stdout + stderr).not_to include('LYRIC_SENTINEL')
      stdout
    end
  end

  it 'prints unchanged snapshots without track changes or text bodies' do
    expect(diff).to eq("====== TRACKS ======\n====== PLAYLISTS ======\n====== PLAYS ======\n")
  end

  it 'summarizes changed lyrics without old or new text through the rake entry point' do
    new_tracks.first['lyrics'] = "LYRIC_SENTINEL_NEW\nLYRIC_SENTINEL_NEW_SECOND_LINE"

    expect(diff(rake: true)).to include("Changed: first track - fixture artist\n  lyrics: changed\n")
  end

  it 'summarizes lyrics added to an empty field' do
    old_tracks.first['lyrics'] = ''

    expect(diff).to include('  lyrics: changed')
  end

  it 'summarizes lyrics cleared to empty' do
    new_tracks.first['lyrics'] = ''

    expect(diff).to include('  lyrics: changed')
  end

  it 'reports added and deleted tracks without printing their lyrics' do
    old_tracks.pop
    new_tracks.shift

    expect(diff).to include('Deleted: first track - fixture artist', 'Added: second track - fixture artist')
  end

  it 'keeps multiline comments in the usual metadata diff style' do
    old_tracks.first['comments'] = "old comment\nsecond line"
    new_tracks.first['comments'] = "new comment\n雪"

    expect(diff).to include("  comments: old comment\nsecond line → new comment\n雪")
  end

  it 'reports comments being cleared' do
    new_tracks.first['comments'] = ''

    expect(diff).to include("  comments: #{old_tracks.first['comments']} → \n")
  end

  it 'reports comments added to an empty field' do
    old_tracks.first['comments'] = ''

    expect(diff).to include("  comments:  → #{new_tracks.first['comments']}")
  end

  %i[old_tracks new_tracks].each do |side|
    %w[lyrics comments].each do |field|
      it "tolerates #{side} missing #{field} without inventing a value or hiding other edits" do
        public_send(side).first.delete(field)
        new_tracks.first['rating'] = 80

        output = diff
        expect(output).to include('  rating: 60 → 80')
        expect(output).not_to include("  #{field}:")
      end
    end
  end

  it 'compares two legacy snapshots with both text fields absent' do
    [old_tracks, new_tracks].flatten.each do |track|
      track.delete('lyrics')
      track.delete('comments')
    end

    expect(diff).to eq("====== TRACKS ======\n====== PLAYLISTS ======\n====== PLAYS ======\n")
  end

  it 'does not report text changes just because an old snapshot lacks both fields' do
    old_tracks.each do |track|
      track.delete('lyrics')
      track.delete('comments')
    end

    expect(diff).to eq("====== TRACKS ======\n====== PLAYLISTS ======\n====== PLAYS ======\n")
  end

  it 'still compares comments when only the old lyrics field is absent' do
    old_tracks.first.delete('lyrics')
    new_tracks.first['comments'] = 'changed comment'

    expect(diff).to include("  comments: #{old_tracks.first['comments']} → changed comment")
  end

  it 'preserves metadata, playlist membership, and play reports alongside lyrics changes' do
    new_tracks.first.merge!('lyrics' => '', 'rating' => 80, 'play_count' => 4)
    new_playlists.first['name'] = 'renamed playlist'
    new_playlists.first['tracks'] = [new_tracks.last['id']]

    expect(diff).to eq(<<~OUTPUT)
      ====== TRACKS ======
      Changed: first track - fixture artist
        rating: 60 → 80
        lyrics: changed

      ====== PLAYLISTS ======
      Changed: fixture playlist
        name: fixture playlist → renamed playlist
       Removed: first track - fixture artist
       Added: second track - fixture artist

      ====== PLAYS ======
      first track - fixture artist: 3 → 4
    OUTPUT
  end
end
