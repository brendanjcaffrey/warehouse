function fix_sort_name(model) {
  model.sort_name = model.sort_name == "" ? model.name : model.sort_name;
}

function seconds_to_time(seconds) {
  var min = Math.floor(Math.ceil(seconds) / 60);
  var sec = Math.ceil(seconds) % 60;
  return String(min) + ":" + (sec < 10 ? "0" : "") + String(sec);
}

function ext_to_type(ext) {
  switch (ext) {
    case 'mp3': return 'audio/mpeg';
    case 'mp4': return 'audio/mp4';
    case 'm4a': return 'audio/mp4';
    case 'aif': return 'audio/aif';
    case 'aiff': return 'audio/aif';
    case 'wav': return 'audio/wav';
  }
}

var GenreIndices = ["id", "name"];
var ArtistIndices = ["id", "name", "sort_name"];
var AlbumIndices = ["id", "artist_id", "name", "sort_name"];
var TrackIndices = ["id", "name", "sort_name", "artist_id", "album_id", "genre_id",
                    "duration", "start", "finish", "track", "track_count", "disc",
                    "disc_count", "play_count", "ext"];

var Genre = function(row) {
  for (index in GenreIndices) {
    this[GenreIndices[index]] = row[index];
  }
}

var Artist = function(row) {
  for (index in ArtistIndices) {
    this[ArtistIndices[index]] = row[index];
  }

  fix_sort_name(this);
}

var Album = function(row) {
  for (index in AlbumIndices) {
    this[AlbumIndices[index]] = row[index];
  }

  fix_sort_name(this);
}

var Track = function(row, artists, albums, genres) {
  for (index in TrackIndices) {
    this[TrackIndices[index]] = row[index]
  }

  this.time = seconds_to_time(this.duration);
  this.artist = artists[this.artist_id].name;
  this.sort_artist = artists[this.artist_id].sort_name;
  this.album = albums[this.album_id].name;
  this.sort_album = albums[this.album_id].sort_name;
  this.genre = genres[this.genre_id].name;
  fix_sort_name(this);
}
