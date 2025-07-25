require 'json'
require 'algorithms'

year = Time.now.year
old_tracks_file = Dir.glob("tracks/#{year - 1}*.json").sort[-1]
new_tracks_file = Dir.glob("tracks/#{year}*.json").sort[-1]
puts "Comparing iTunes libarary on #{old_tracks_file.split('/').last.split('.').first} and #{new_tracks_file.split('/').last.split('.').first}"
old_tracks = JSON.parse(File.read(old_tracks_file))
new_tracks = JSON.parse(File.read(new_tracks_file))

updated_track_ids = {}
updated_track_ids_file = File.join(__dir__, 'updated_track_ids.json')
puts "Using updated track IDs from #{updated_track_ids_file}" if File.exist?(updated_track_ids_file)
updated_track_ids = JSON.parse(File.read(updated_track_ids_file)) if File.exist?(updated_track_ids_file)

old_tracks.each do |track|
  next unless updated_track_ids.key?(track['id'])

  found = false
  new_tracks.each do |new_track|
    if new_track['id'] == updated_track_ids[track['id']]
      new_track['id'] = track['id']
      found = true
    end
  end

  unless found
    puts "new track not found! #{track}"
    exit
  end
end
new_tracks.sort_by! { |t| t['id'] }
old_tracks.sort_by! { |t| t['id'] }

Track = Struct.new(:name, :plays) do
  def self.build(track_json, prev_plays = 0)
    plays = track_json['play_count'] - prev_plays
    Track.new("#{track_json['name']} - #{track_json['artist']} (#{plays})", plays)
  end
end
tracks = Containers::PriorityQueue.new

old_idx = 0
new_idx = 0
while old_idx < old_tracks.size || new_idx < new_tracks.size
  if old_idx >= old_tracks.size
    track = Track.build(new_tracks[new_idx])
    tracks.push(track, track.plays)
    new_idx += 1
    next
  end
  if new_idx >= new_tracks.size
    old_idx += 1 # track was deleted, ignore
    next
  end

  old_track = old_tracks[old_idx]
  new_track = new_tracks[new_idx]

  if old_track['id'] == new_track['id']
    track = Track.build(new_track, old_track['play_count'])
    tracks.push(track, track.plays)

    old_idx += 1
    new_idx += 1
  elsif old_track['id'] < new_track['id']
    old_idx += 1 # deleted, ignore
  else
    track = Track.build(new_track)
    tracks.push(track, track.plays)
    new_idx += 1
  end
end

n = 25
puts "\nTop #{n} played songs:"
n.times do
  puts tracks.pop.name
end
