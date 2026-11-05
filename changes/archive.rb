require 'pg'
require 'date'
require 'fileutils'

today = Date.today.strftime('%Y%m%d')
directory = ENV.fetch('CHANGES_DIRECTORY', __dir__)
tracks_out = File.join(directory, 'tracks', "#{today}.json")
playlists_out = File.join(directory, 'playlists', "#{today}.json")

finished = <<-SQL
  SELECT COUNT(*) FROM export_finished
SQL

tracks = <<~SQL
  SELECT COALESCE(json_agg(data), '[]'::json) FROM (
    SELECT t.id, t.name, t.sort_name, a.name AS artist, COALESCE(aa.name,'') AS album_artist, COALESCE(al.name,'') AS album, g.name AS genre, t.year, t.duration, t.start, t.finish, t.track_number, t.disc_number, t.play_count, t.rating, music_filename, artwork_filename, t.lyrics, t.comments
      FROM tracks AS t
        JOIN artists AS a ON t.artist_id = a.id
        FULL OUTER JOIN artists AS aa ON t.album_artist_id = aa.id
        FULL OUTER JOIN albums AS al ON t.album_id = al.id
        JOIN genres AS g ON t.genre_id = g.id
    ORDER BY t.id
  ) data
SQL

playlists = <<~SQL
  SELECT COALESCE(json_agg(data), '[]'::json) FROM (
    SELECT id, name, parent_id,
      (SELECT array_agg(track_id ORDER BY track_id) FROM playlist_tracks WHERE playlist_id=id) AS tracks
    FROM playlists
    WHERE is_library=0
    ORDER BY id
  ) data
SQL

db = PG.connect(ENV.fetch('CHANGES_DATABASE_URL') { { user: 'warehouse', dbname: 'warehouse' } })
res = db.exec(finished)
val = res.getvalue(0, 0)
if val.to_s == '0'
  puts "export did not finish! #{val.inspect}"
  exit 1
end

# read json directly so copy text escaping cannot alter the archived values.
FileUtils.mkdir_p([File.dirname(tracks_out), File.dirname(playlists_out)])
File.write(tracks_out, "#{db.exec(tracks).getvalue(0, 0)}\n")
File.write(playlists_out, "#{db.exec(playlists).getvalue(0, 0)}\n")
db.close
