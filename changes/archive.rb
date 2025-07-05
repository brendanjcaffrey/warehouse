require 'pg'
require 'date'

today = Date.today.strftime('%Y%m%d')
tracks_out = __dir__ + "/tracks/#{today}.json"
playlists_out = __dir__ + "/playlists/#{today}.json"

finished = <<-SQL
  SELECT COUNT(*) FROM export_finished
SQL

tracks = <<~SQL
  COPY (
    SELECT array_to_json(array_agg(row_to_json(data))) FROM (
      SELECT t.id, t.name, t.sort_name, a.name AS artist, COALESCE(aa.name,'') AS album_artist, COALESCE(al.name,'') AS album, g.name AS genre, t.year, t.duration, t.start, t.finish, t.track_number, t.disc_number, t.play_count, t.rating, ext, file_md5, artwork_filename
        FROM tracks AS t
          JOIN artists AS a ON t.artist_id = a.id
          FULL OUTER JOIN artists AS aa ON t.album_artist_id = aa.id
          FULL OUTER JOIN albums AS al ON t.album_id = al.id
          JOIN genres AS g ON t.genre_id = g.id
      ORDER BY t.id
    ) data
  ) TO STDOUT
SQL

playlists = <<~SQL
  COPY (
    SELECT array_to_json(array_agg(row_to_json(data))) FROM (
      SELECT id, name, parent_id,
        (SELECT array_agg(track_id ORDER BY track_id) FROM playlist_tracks WHERE playlist_id=id) AS tracks
      FROM playlists
      WHERE is_library=0
      ORDER BY id
    ) data
  ) TO STDOUT
SQL

db = PG.connect(user: 'warehouse', dbname: 'warehouse')
res = db.exec(finished)
val = res.getvalue(0, 0)
if val.to_s == '0'
  puts "export did not finish! #{val.inspect}"
  exit 1
end

f = File.open(tracks_out, 'w')
db.copy_data(tracks) do
  while row = db.get_copy_data
    f.puts(row)
  end
end
f.close

f = File.open(playlists_out, 'w')
db.copy_data(playlists) do
  while row = db.get_copy_data
    f.puts(row)
  end
end
f.close

# https://dba.stackexchange.com/a/147827
`sed -i '' -e 's/\\\\\\\\/\\\\/g' #{tracks_out}`
`sed -i '' -e 's/\\\\\\\\/\\\\/g' #{playlists_out}`
