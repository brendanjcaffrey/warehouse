require 'json'

# keys that were once archived for tracks but are no longer
removed_track_keys = ['file']
# keys that were renamed for tracks
map_removed_track_keys = { 'disc' => 'disc_number', 'track' => 'track_number' }
# keys that were added at some point for tracks
added_track_keys = %w[ext file_md5 artwork_filename]

tracks = Dir.glob('tracks/*.json').sort[-2..-1]
playlists = Dir.glob('playlists/*.json').sort[-2..-1]

old_tracks = JSON.load(File.read(tracks.first))
new_tracks = JSON.load(File.read(tracks.last))

old_idx = 0
new_idx = 0

def desc(track)
  track['name'] + ' - ' + track['artist']
end

def desc_id(track_id, list)
  track = list.bsearch { |track| track_id <=> track['id'] }
  if track.nil?
    "Not found (#{track_id})"
  else
    desc(track)
  end
end

puts '====== TRACKS ======'

Changeset = Struct.new(:desc, :changed, :values) do
  def <=>(other)
    return desc <=> other.desc if desc != other.desc
    return changed <=> other.changed if changed != other.changed

    values.count <=> other.values.count
  end
end
changesets = []
deleted_count = 0
while old_idx < old_tracks.size || new_idx < new_tracks.size
  old_track = old_tracks[old_idx]
  old_track = old_track.reject { |k, _v| k == 'play_count' } if old_track
  new_track = new_tracks[new_idx]
  new_track = new_track.reject { |k, _v| k == 'play_count' } if new_track

  if old_idx >= old_tracks.size
    changesets.push(Changeset.new(desc(new_track), 'Added', []))
    new_idx += 1
    next
  end
  if new_idx >= new_tracks.size
    changesets.push(Changeset.new(desc(old_track), 'Deleted', []))
    old_idx += 1
    deleted_count += 1
    next
  end

  if old_track['id'] == new_track['id']
    if old_track != new_track
      old_track_keys = old_track.keys - removed_track_keys
      new_track_keys = new_track.keys
      map_removed_track_keys.each do |old_key, new_key|
        next unless old_track[old_key]

        old_track[new_key] = old_track[old_key]
        old_track_keys[old_track_keys.index(old_key)] = new_key
      end
      added_track_keys.each do |key|
        new_track_keys -= [key] if new_track_keys.include?(key) && !old_track_keys.include?(key)
      end

      if old_track_keys != new_track_keys
        puts desc(old_track) + ': keys don\'t match! Aborting!'
        exit
      end

      changeset = Changeset.new(desc(old_track), 'Changed', [])
      old_track_keys.select { |key| old_track[key] != new_track[key] }.each do |key|
        changeset.values.push("  #{key}: #{old_track[key]} → #{new_track[key]}")
      end

      changesets.push(changeset) unless changeset.values.empty?
    end

    old_idx += 1
    new_idx += 1
  elsif old_track['id'] < new_track['id']
    changesets.push(Changeset.new(desc(old_track), 'Deleted', []))
    old_idx += 1
    deleted_count += 1
  else
    changesets.push(Changeset.new(desc(new_track), 'Added', []))
    new_idx += 1
  end
end

if deleted_count >= 1000
  puts "Deleted count: #{deleted_count}, there must be an issue with the data, exiting early"
  exit
end

changesets.sort.each do |changeset|
  puts changeset.changed + ': ' + changeset.desc
  changeset.values.each do |value|
    puts value
  end
  puts ''
end

old_playlists = JSON.load(File.read(playlists.first))
new_playlists = JSON.load(File.read(playlists.last))

old_idx = 0
new_idx = 0

puts '====== PLAYLISTS ======'

while old_idx < old_playlists.size && new_idx < new_playlists.size
  old_playlist = old_playlists[old_idx]
  new_playlist = new_playlists[new_idx]

  if old_playlist['id'] == new_playlist['id']
    if old_playlist != new_playlist
      puts 'Changed: ' + old_playlist['name']

      if old_playlist.keys != new_playlist.keys
        puts 'Keys don\'t match! Aborting!'
        exit
      end
      keys = old_playlist.keys - ['tracks']

      keys.select { |key| old_playlist[key] != new_playlist[key] }.each do |key|
        puts "  #{key}: #{old_playlist[key]} → #{new_playlist[key]}"
      end

      changesets = []
      old_track_ids = old_playlist['tracks'] || []
      new_track_ids = new_playlist['tracks'] || []
      old_track_idx = 0
      new_track_idx = 0
      while old_track_idx < old_track_ids.size || new_track_idx < new_track_ids.size
        if old_track_idx >= old_track_ids.size
          changesets.push(Changeset.new(desc_id(new_track_ids[new_track_idx], new_tracks), 'Added', []))
          new_track_idx += 1
          next
        end
        if new_track_idx >= new_track_ids.size
          changesets.push(Changeset.new(desc_id(old_track_ids[old_track_idx], old_tracks), 'Removed', []))
          old_track_idx += 1
          next
        end
        old_track_id = old_track_ids[old_track_idx]
        new_track_id = new_track_ids[new_track_idx]

        if old_track_id == new_track_id
          old_track_idx += 1
          new_track_idx += 1
        elsif old_track_id < new_track_id
          changesets.push(Changeset.new(desc_id(old_track_id, old_tracks), 'Removed', []))
          old_track_idx += 1
        else
          changesets.push(Changeset.new(desc_id(new_track_id, new_tracks), 'Added', []))
          new_track_idx += 1
        end
      end

      changesets.sort.each do |changeset|
        puts " #{changeset.changed}: #{changeset.desc}"
      end
      puts "\n"
    end

    old_idx += 1
    new_idx += 1
  elsif old_playlist['id'] < new_playlist['id']
    puts 'Deleted: ' + old_playlist['name'] + "\n\n"
    old_idx += 1
  else
    puts 'Added: ' + new_playlist['name'] + "\n\n"
    new_idx += 1
  end
end

puts '====== PLAYS ======'

plays = []
old_idx = 0
new_idx = 0
while old_idx < old_tracks.size || new_idx < new_tracks.size
  if old_idx >= old_tracks.size
    new_track = new_tracks[new_idx].select { |k, _v| %w[play_count id].include?(k) }
    plays.push("#{desc_id(new_track['id'], new_tracks)}: 0 → #{new_track['play_count']}") if new_track['play_count'] > 0
    new_idx += 1
    next
  end
  if new_idx >= new_tracks.size
    old_idx += 1
    next
  end

  old_track = old_tracks[old_idx].select { |k, _v| %w[play_count id].include?(k) }
  new_track = new_tracks[new_idx].select { |k, _v| %w[play_count id].include?(k) }

  if old_track['id'] == new_track['id']
    if old_track != new_track
      if old_track.keys != new_track.keys
        puts 'Keys don\'t match! Aborting!'
        exit
      end

      plays.push("#{desc_id(new_track['id'], new_tracks)}: #{old_track['play_count']} → #{new_track['play_count']}")
    end

    old_idx += 1
    new_idx += 1
  elsif old_track['id'] < new_track['id']
    old_idx += 1
  else
    plays.push("#{desc_id(new_track['id'], new_tracks)}: 0 → #{new_track['play_count']}") if new_track['play_count'] > 0
    new_idx += 1
  end
end
plays.sort.each do |play|
  puts play
end
