require 'json'
require 'algorithms'
require 'set'

year = Time.now.year
old_tracks_file = Dir.glob("tracks/#{year-1}*.json").sort[-1]
new_tracks_file = Dir.glob("tracks/#{year}*.json").sort[-1]
puts "Comparing iTunes libarary on #{old_tracks_file.split('/').last.split('.').first} and #{new_tracks_file.split('/').last.split('.').first}"
old_tracks = JSON.load(File.read(old_tracks_file))
new_tracks = JSON.load(File.read(new_tracks_file))

# this is silly, but i converted the files, so let's map them
map = Set.new(%w(99D07E4CBA6CB140 D4BEA19756905E1D 9105BFAAAE52EA97 3BFA115DFF5435CC 83B6AA68F2DD38E6 7EB893B6F575CEDB D164038AEFFF941E 790D84FCA424B2A4 02CFA19053094C32 2A5E581DA743925F D274D4DE56031E30 C35770D4E5E0457E 3ABA4FAE5F063A2F 4AF11B0A26D90ABF 14770D92F58AA812 60203E50E78E4999 434F8DDBCD1940AC FE66BE9E1B4B42BF 2853B2EE9C2E19BE 236C8F27FE3B660B EB2E7665ACA71340 F454CA5BBD3B6A94 2E66CC0A74F21039 F55415A5B7F71A88 1DD2A99CEBBFB982 4F67060C07B2188B 5ADABAB7303B4F1F C9FA8772C54D1BE4 B0A63160B2A94AFA 4938CD795AD0864A EAE3F2FB6C20B79F 28AA854466859FE3 32916F8C652FAEAD FE4F81245AABBFBB 77E1D1C8E60251FC 3A41582A177D8DB7 846B7CDABEB25BE5 197F6142ED15B84B 5E50C0CD4E62FD68 A5726CA0C900B264 4E19D3FA473D95D6 0BBD8767615711ED 29435704151C6459 2E68224DB4A95FDD B050090A05E76B07 EDAA42CDE650046B 45F7682AAFE5D21C E19A5083AB360EDF 24BA5103BDC733CC FF287F89368EA9E3 400460B39B72C85F D40354356DA02259 1359A6F63F5659B4 ABE8C598D8E0437A))

old_tracks.each do |track|
  if map.include?(track['id'])
    found = false
    new_tracks.each do |new_track|
      if track['name'] == new_track['name'] && track['artist'] == new_track['artist']
        new_track['id'] = track['id']
        found = true
      end
    end

    if !found
      puts "not found! #{track}"
      exit
    end
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
