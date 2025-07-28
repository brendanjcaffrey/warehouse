# frozen_string_literal: true

GENRE_SQL = 'SELECT id, name FROM genres;'
ARTIST_SQL = 'SELECT id, name, sort_name FROM artists;'
ALBUM_SQL = 'SELECT id, name, sort_name FROM albums;'
TRACK_SQL = <<~SQL
  SELECT
      t.id, t.name, t.sort_name, t.artist_id, t.album_artist_id, t.album_id, t.genre_id, t.year,
      t.duration, t.start, t.finish, t.track_number, t.disc_number, t.play_count, t.rating,
      t.music_filename, t.artwork_filename, STRING_AGG(pt.playlist_id, ',') AS playlist_ids
  FROM
      tracks t
  LEFT JOIN
      playlist_tracks pt
  ON
      t.id = pt.track_id
  GROUP BY
      t.id
SQL
LIBRARY_PLAYLIST_IDS_SQL = 'SELECT id FROM playlists WHERE is_library = 1;'
PLAYLIST_SQL = <<~SQL
  SELECT
      p.id, p.name, p.parent_id, p.is_library,
      STRING_AGG(pt.track_id, ',') AS track_ids
  FROM
      playlists p
  LEFT JOIN
      playlist_tracks pt
  ON
      p.id = pt.playlist_id
  GROUP BY
      p.id, p.name, p.parent_id, p.is_library;
SQL
LIBRARY_METADATA_SQL = 'SELECT total_file_size FROM library_metadata;'
EXPORT_FINISHED_SQL = 'SELECT finished_at FROM export_finished;'

TRACK_EXISTS_SQL = 'SELECT COUNT(*) FROM tracks WHERE id=$1;'
TRACK_HAS_MUSIC_SQL = 'SELECT EXISTS(SELECT 1 FROM tracks WHERE music_filename=$1);'
TRACK_HAS_ARTWORK_SQL = 'SELECT EXISTS(SELECT 1 FROM tracks WHERE artwork_filename=$1);'

CREATE_PLAY_SQL = 'INSERT INTO plays (track_id) VALUES ($1);'
INCREMENT_PLAY_SQL = 'UPDATE tracks SET play_count=play_count+1 WHERE id=$1;'

DELETE_RATING_UPDATE_SQL = 'DELETE FROM rating_updates WHERE track_id=$1;'
CREATE_RATING_UPDATE_SQL = 'INSERT INTO rating_updates (track_id, rating) VALUES ($1, $2);'
UPDATE_RATING_SQL = 'UPDATE tracks SET rating=$1 WHERE id=$2;'

DELETE_NAME_UPDATE_SQL = 'DELETE FROM name_updates WHERE track_id=$1;'
CREATE_NAME_UPDATE_SQL = 'INSERT INTO name_updates (track_id, name) VALUES ($1, $2);'
UPDATE_NAME_SQL = 'UPDATE tracks SET name=$1 WHERE id=$2;'

DELETE_YEAR_UPDATE_SQL = 'DELETE FROM year_updates WHERE track_id=$1;'
CREATE_YEAR_UPDATE_SQL = 'INSERT INTO year_updates (track_id, year) VALUES ($1, $2);'
UPDATE_YEAR_SQL = 'UPDATE tracks SET year=$1 WHERE id=$2;'

DELETE_START_UPDATE_SQL = 'DELETE FROM start_updates WHERE track_id=$1;'
CREATE_START_UPDATE_SQL = 'INSERT INTO start_updates (track_id, start) VALUES ($1, $2);'
UPDATE_START_SQL = 'UPDATE tracks SET start=$1 WHERE id=$2;'

DELETE_FINISH_UPDATE_SQL = 'DELETE FROM finish_updates WHERE track_id=$1;'
CREATE_FINISH_UPDATE_SQL = 'INSERT INTO finish_updates (track_id, finish) VALUES ($1, $2);'
UPDATE_FINISH_SQL = 'UPDATE tracks SET finish=$1 WHERE id=$2;'

DELETE_ARTIST_UPDATE_SQL = 'DELETE FROM artist_updates WHERE track_id=$1;'
CREATE_ARTIST_UPDATE_SQL = 'INSERT INTO artist_updates (track_id, artist) VALUES ($1, $2);'
ARTIST_ID_SQL = 'SELECT id FROM artists WHERE name=$1;'
CREATE_ARTIST_SQL = 'INSERT INTO artists (name, sort_name) VALUES ($1, \'\') RETURNING id;'
UPDATE_ARTIST_SQL = 'UPDATE tracks SET artist_id=$1 WHERE id=$2;'

DELETE_GENRE_UPDATE_SQL = 'DELETE FROM genre_updates WHERE track_id=$1;'
CREATE_GENRE_UPDATE_SQL = 'INSERT INTO genre_updates (track_id, genre) VALUES ($1, $2);'
GENRE_ID_SQL = 'SELECT id FROM genres WHERE name=$1;'
CREATE_GENRE_SQL = 'INSERT INTO genres (name) VALUES ($1) RETURNING id;'
UPDATE_GENRE_SQL = 'UPDATE tracks SET genre_id=$1 WHERE id=$2;'

DELETE_ALBUM_ARTIST_UPDATE_SQL = 'DELETE FROM album_artist_updates WHERE track_id=$1;'
CREATE_ALBUM_ARTIST_UPDATE_SQL = 'INSERT INTO album_artist_updates (track_id, album_artist) VALUES ($1, $2);'
UPDATE_ALBUM_ARTIST_SQL = 'UPDATE tracks SET album_artist_id=$1 WHERE id=$2;'

DELETE_ALBUM_UPDATE_SQL = 'DELETE FROM album_updates WHERE track_id=$1;'
CREATE_ALBUM_UPDATE_SQL = 'INSERT INTO album_updates (track_id, album) VALUES ($1, $2);'
ALBUM_ID_SQL = 'SELECT id FROM albums WHERE name=$1;'
CREATE_ALBUM_SQL = 'INSERT INTO albums (name, sort_name) VALUES ($1, \'\') RETURNING id;'
UPDATE_ALBUM_SQL = 'UPDATE tracks SET album_id=$1 WHERE id=$2;'

DELETE_ARTWORK_UPDATE_SQL = 'DELETE FROM artwork_updates WHERE track_id=$1;'
CREATE_ARTWORK_UPDATE_SQL = 'INSERT INTO artwork_updates (track_id, artwork_filename) VALUES ($1, $2);'
UPDATE_ARTWORK_SQL = 'UPDATE tracks SET artwork_filename=$1 WHERE id=$2;'

UPDATE_EXPORT_FINISHED_SQL = 'UPDATE export_finished SET finished_at=current_timestamp;'
