CREATE TABLE genres (
    id SERIAL NOT NULL,
    name TEXT NOT NULL
);
CREATE TABLE artists (
    id SERIAL NOT NULL,
    name TEXT NOT NULL,
    sort_name TEXT NOT NULL
);
CREATE TABLE albums (
    id SERIAL NOT NULL,
    name TEXT NOT NULL,
    sort_name TEXT NOT NULL
);
CREATE TABLE tracks (
    id CHAR(16) PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    sort_name TEXT NOT NULL,
    artist_id INTEGER,
    album_artist_id INTEGER,
    album_id INTEGER,
    genre_id INTEGER,
    year INTEGER NOT NULL,
    duration REAL NOT NULL,
    start REAL NOT NULL,
    finish REAL NOT NULL,
    track_number INTEGER NOT NULL,
    disc_number INTEGER NOT NULL,
    play_count INTEGER NOT NULL,
    rating INTEGER NOT NULL,
    ext TEXT NOT NULL,
    file_md5 CHAR(32) NOT NULL,
    artwork_filename CHAR(36)
);
CREATE TABLE playlists (
    id CHAR(16) PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    is_library INTEGER NOT NULL,
    parent_id VARCHAR(16)
);
CREATE TABLE playlist_tracks (
    playlist_id CHAR(16) NOT NULL,
    track_id CHAR(16) NOT NULL
);
CREATE TABLE plays (
    track_id CHAR(16) NOT NULL
);
CREATE TABLE rating_updates (
    track_id CHAR(16) NOT NULL,
    rating INTEGER NOT NULL
);
CREATE TABLE name_updates (
    track_id CHAR(16) NOT NULL,
    name TEXT NOT NULL
);
CREATE TABLE artist_updates (
    track_id CHAR(16) NOT NULL,
    artist TEXT NOT NULL
);
CREATE TABLE album_updates (
    track_id CHAR(16) NOT NULL,
    album TEXT NOT NULL
);
CREATE TABLE album_artist_updates (
    track_id CHAR(16) NOT NULL,
    album_artist TEXT NOT NULL
);
CREATE TABLE genre_updates (
    track_id CHAR(16) NOT NULL,
    genre TEXT NOT NULL
);
CREATE TABLE year_updates (
    track_id CHAR(16) NOT NULL,
    year INTEGER NOT NULL
);
CREATE TABLE start_updates (
    track_id CHAR(16) NOT NULL,
    start REAL NOT NULL
);
CREATE TABLE finish_updates (
    track_id CHAR(16) NOT NULL,
    finish REAL NOT NULL
);
CREATE TABLE artwork_updates (
    track_id CHAR(16),
    artwork_filename CHAR(36)
);
CREATE TABLE library_metadata (
    total_file_size BIGINT NOT NULL
);
CREATE TABLE export_finished (
    finished_at TIMESTAMP NOT NULL
);
