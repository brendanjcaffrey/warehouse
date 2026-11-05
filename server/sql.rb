# frozen_string_literal: true

GENRE_SQL = 'SELECT id, name FROM genres;'
ARTIST_SQL = 'SELECT id, name, sort_name FROM artists;'
ALBUM_SQL = 'SELECT id, name, sort_name FROM albums;'
TRACK_SQL = <<~SQL
  SELECT
      t.id, t.name, t.sort_name, t.artist_id, t.album_artist_id, t.album_id, t.genre_id, t.year,
      t.duration, t.start, t.finish, t.track_number, t.disc_number, t.play_count, t.rating,
      t.music_filename, t.artwork_filename, t.added_date, t.lyrics, t.comments, STRING_AGG(pt.playlist_id, ',') AS playlist_ids
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

RECORD_PLAY_SQL = <<~SQL
  WITH updated_track AS (
    UPDATE tracks SET play_count=play_count+1 WHERE id=$1 RETURNING id
  ), recorded_play AS (
    INSERT INTO plays (track_id) SELECT id FROM updated_track
  )
  UPDATE export_finished SET finished_at=current_timestamp
  WHERE EXISTS (SELECT 1 FROM updated_track);
SQL

# the json payload keeps optional field names and explicit empty/zero values together.
# legacy pending inserts read their delete results to order replacements within the statement.
UPDATE_TRACK_SQL = <<~SQL
  WITH requested AS (
    SELECT tracks.id, $2::jsonb AS fields FROM tracks WHERE id=$1 FOR UPDATE
  ), artist_names AS (
    SELECT fields->>'artist' AS name FROM requested WHERE fields ? 'artist'
    UNION
    SELECT NULLIF(fields->>'albumArtist', '') FROM requested WHERE fields ? 'albumArtist'
  ), created_artists AS (
    INSERT INTO artists (name, sort_name)
    SELECT name, '' FROM artist_names
    WHERE name IS NOT NULL AND NOT EXISTS (SELECT 1 FROM artists WHERE artists.name=artist_names.name)
    RETURNING id, name
  ), selected_artists AS (
    SELECT id, name FROM artists WHERE name IN (SELECT name FROM artist_names)
    UNION ALL
    SELECT id, name FROM created_artists
  ), created_albums AS (
    INSERT INTO albums (name, sort_name)
    SELECT fields->>'album', '' FROM requested
    WHERE fields ? 'album' AND fields->>'album' <> ''
      AND NOT EXISTS (SELECT 1 FROM albums WHERE name=fields->>'album')
    RETURNING id, name
  ), selected_albums AS (
    SELECT id, name FROM albums WHERE name IN (SELECT fields->>'album' FROM requested)
    UNION ALL
    SELECT id, name FROM created_albums
  ), created_genres AS (
    INSERT INTO genres (name)
    SELECT fields->>'genre' FROM requested
    WHERE fields ? 'genre' AND NOT EXISTS (SELECT 1 FROM genres WHERE name=fields->>'genre')
    RETURNING id, name
  ), selected_genres AS (
    SELECT id, name FROM genres WHERE name IN (SELECT fields->>'genre' FROM requested)
    UNION ALL
    SELECT id, name FROM created_genres
  ), updated_track AS (
    UPDATE tracks AS track SET
      name=CASE WHEN fields ? 'name' THEN fields->>'name' ELSE track.name END,
      artist_id=CASE WHEN fields ? 'artist' THEN
        (SELECT id FROM selected_artists WHERE name=fields->>'artist' ORDER BY id LIMIT 1) ELSE track.artist_id END,
      album_artist_id=CASE WHEN fields ? 'albumArtist' THEN
        (SELECT id FROM selected_artists WHERE name=NULLIF(fields->>'albumArtist', '') ORDER BY id LIMIT 1) ELSE track.album_artist_id END,
      album_id=CASE WHEN fields ? 'album' THEN
        (SELECT id FROM selected_albums WHERE name=NULLIF(fields->>'album', '') ORDER BY id LIMIT 1) ELSE track.album_id END,
      genre_id=CASE WHEN fields ? 'genre' THEN
        (SELECT id FROM selected_genres WHERE name=fields->>'genre' ORDER BY id LIMIT 1) ELSE track.genre_id END,
      year=CASE WHEN fields ? 'year' THEN (fields->>'year')::integer ELSE track.year END,
      start=CASE WHEN fields ? 'start' THEN (fields->>'start')::real ELSE track.start END,
      finish=CASE WHEN fields ? 'finish' THEN (fields->>'finish')::real ELSE track.finish END,
      rating=CASE WHEN fields ? 'rating' THEN (fields->>'rating')::integer ELSE track.rating END,
      artwork_filename=CASE WHEN fields ? 'artwork' THEN NULLIF(fields->>'artwork', '') ELSE track.artwork_filename END,
      lyrics=CASE WHEN fields ? 'lyrics' THEN fields->>'lyrics' ELSE track.lyrics END,
      comments=CASE WHEN fields ? 'comments' THEN fields->>'comments' ELSE track.comments END
    FROM requested WHERE track.id=requested.id
    RETURNING track.id, requested.fields
  ), deleted_name AS (
    DELETE FROM name_updates AS pending USING updated_track AS changed
    WHERE pending.track_id=changed.id AND changed.fields ? 'name'
    RETURNING pending.track_id
  ), queued_name AS (
    INSERT INTO name_updates (track_id, name)
    SELECT changed.id, changed.fields->>'name' FROM updated_track AS changed
    CROSS JOIN (SELECT count(*) FROM deleted_name) AS deleted
    WHERE changed.fields ? 'name'
  ), deleted_artist AS (
    DELETE FROM artist_updates AS pending USING updated_track AS changed
    WHERE pending.track_id=changed.id AND changed.fields ? 'artist'
    RETURNING pending.track_id
  ), queued_artist AS (
    INSERT INTO artist_updates (track_id, artist)
    SELECT changed.id, changed.fields->>'artist' FROM updated_track AS changed
    CROSS JOIN (SELECT count(*) FROM deleted_artist) AS deleted
    WHERE changed.fields ? 'artist'
  ), deleted_album_artist AS (
    DELETE FROM album_artist_updates AS pending USING updated_track AS changed
    WHERE pending.track_id=changed.id AND changed.fields ? 'albumArtist'
    RETURNING pending.track_id
  ), queued_album_artist AS (
    INSERT INTO album_artist_updates (track_id, album_artist)
    SELECT changed.id, changed.fields->>'albumArtist' FROM updated_track AS changed
    CROSS JOIN (SELECT count(*) FROM deleted_album_artist) AS deleted
    WHERE changed.fields ? 'albumArtist'
  ), deleted_album AS (
    DELETE FROM album_updates AS pending USING updated_track AS changed
    WHERE pending.track_id=changed.id AND changed.fields ? 'album'
    RETURNING pending.track_id
  ), queued_album AS (
    INSERT INTO album_updates (track_id, album)
    SELECT changed.id, changed.fields->>'album' FROM updated_track AS changed
    CROSS JOIN (SELECT count(*) FROM deleted_album) AS deleted
    WHERE changed.fields ? 'album'
  ), deleted_genre AS (
    DELETE FROM genre_updates AS pending USING updated_track AS changed
    WHERE pending.track_id=changed.id AND changed.fields ? 'genre'
    RETURNING pending.track_id
  ), queued_genre AS (
    INSERT INTO genre_updates (track_id, genre)
    SELECT changed.id, changed.fields->>'genre' FROM updated_track AS changed
    CROSS JOIN (SELECT count(*) FROM deleted_genre) AS deleted
    WHERE changed.fields ? 'genre'
  ), deleted_year AS (
    DELETE FROM year_updates AS pending USING updated_track AS changed
    WHERE pending.track_id=changed.id AND changed.fields ? 'year'
    RETURNING pending.track_id
  ), queued_year AS (
    INSERT INTO year_updates (track_id, year)
    SELECT changed.id, (changed.fields->>'year')::integer FROM updated_track AS changed
    CROSS JOIN (SELECT count(*) FROM deleted_year) AS deleted
    WHERE changed.fields ? 'year'
  ), deleted_start AS (
    DELETE FROM start_updates AS pending USING updated_track AS changed
    WHERE pending.track_id=changed.id AND changed.fields ? 'start'
    RETURNING pending.track_id
  ), queued_start AS (
    INSERT INTO start_updates (track_id, start)
    SELECT changed.id, (changed.fields->>'start')::real FROM updated_track AS changed
    CROSS JOIN (SELECT count(*) FROM deleted_start) AS deleted
    WHERE changed.fields ? 'start'
  ), deleted_finish AS (
    DELETE FROM finish_updates AS pending USING updated_track AS changed
    WHERE pending.track_id=changed.id AND changed.fields ? 'finish'
    RETURNING pending.track_id
  ), queued_finish AS (
    INSERT INTO finish_updates (track_id, finish)
    SELECT changed.id, (changed.fields->>'finish')::real FROM updated_track AS changed
    CROSS JOIN (SELECT count(*) FROM deleted_finish) AS deleted
    WHERE changed.fields ? 'finish'
  ), deleted_rating AS (
    DELETE FROM rating_updates AS pending USING updated_track AS changed
    WHERE pending.track_id=changed.id AND changed.fields ? 'rating'
    RETURNING pending.track_id
  ), queued_rating AS (
    INSERT INTO rating_updates (track_id, rating)
    SELECT changed.id, (changed.fields->>'rating')::integer FROM updated_track AS changed
    CROSS JOIN (SELECT count(*) FROM deleted_rating) AS deleted
    WHERE changed.fields ? 'rating'
  ), deleted_artwork AS (
    DELETE FROM artwork_updates AS pending USING updated_track AS changed
    WHERE pending.track_id=changed.id AND changed.fields ? 'artwork'
    RETURNING pending.track_id
  ), queued_artwork AS (
    INSERT INTO artwork_updates (track_id, artwork_filename)
    SELECT changed.id, NULLIF(changed.fields->>'artwork', '') FROM updated_track AS changed
    CROSS JOIN (SELECT count(*) FROM deleted_artwork) AS deleted
    WHERE changed.fields ? 'artwork'
  ), queued_lyrics AS (
    INSERT INTO lyrics_updates (track_id, lyrics)
    SELECT id, fields->>'lyrics' FROM updated_track WHERE fields ? 'lyrics'
    ON CONFLICT (track_id) DO UPDATE SET lyrics=EXCLUDED.lyrics
  ), queued_comments AS (
    INSERT INTO comments_updates (track_id, comments)
    SELECT id, fields->>'comments' FROM updated_track WHERE fields ? 'comments'
    ON CONFLICT (track_id) DO UPDATE SET comments=EXCLUDED.comments
  )
  UPDATE export_finished SET finished_at=current_timestamp
  WHERE EXISTS (SELECT 1 FROM updated_track);
SQL

# ::int so the value doesn't depend on pg's boolean text rendering
LIBRARY_FROZEN_SQL = 'SELECT frozen::int AS frozen FROM library_state LIMIT 1;'
