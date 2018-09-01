function fixSortName(model) {
  model.sortName = model.sortName == "" ? model.name : model.sortName;
}

function secondsToTime(seconds) {
  var min = Math.floor(Math.ceil(seconds) / 60);
  var sec = Math.ceil(seconds) % 60;
  return String(min) + ":" + (sec < 10 ? "0" : "") + String(sec);
}

function extToType(ext) {
  switch (ext) {
    case 'mp3':  return 'audio/mpeg';
    case 'mp4':  return 'audio/mp4';
    case 'm4a':  return 'audio/mp4';
    case 'aif':  return 'audio/aif';
    case 'aiff': return 'audio/aif';
    case 'wav':  return 'audio/wav';
  }
}

var GenreIndices = ["id", "name"];
var ArtistIndices = ["id", "name", "sortName"];
var AlbumIndices = ["id", "artistId", "name", "sortName"];
var TrackIndices = ["id", "name", "sortName", "artistId", "albumArtistId", "albumId", "genreId", "year",
                    "duration", "start", "finish", "track", "disc", "playCount", "rating", "ext"];
var PlaylistIndices = ["id", "name", "parentId", "isLibrary"];
var PlaylistTracksIndices = ["id", "tracks"];

var Genre = function(row) {
  for (idx in GenreIndices) {
    this[GenreIndices[idx]] = row[idx];
  }
}

var Artist = function(row) {
  for (idx in ArtistIndices) {
    this[ArtistIndices[idx]] = row[idx];
  }

  fixSortName(this);
}

var Album = function(row) {
  for (idx in AlbumIndices) {
    this[AlbumIndices[idx]] = row[idx];
  }

  fixSortName(this);
}

var Track = function(row, artists, albums, genres) {
  for (idx in TrackIndices) {
    this[TrackIndices[idx]] = row[idx]
  }

  this.duration = parseFloat(this.duration);
  this.start = parseFloat(this.start);
  this.finish = parseFloat(this.finish);
  this.time = secondsToTime(this.duration);
  this.artist = artists[this.artistId].name;
  this.sortArtist = artists[this.artistId].sortName;
  this.albumArtist = artists[this.albumArtistId].name;
  this.sortAlbumArtist = artists[this.albumArtistId].sortName;
  this.album = this.albumId ? albums[this.albumId].name : "";
  this.sortAlbum = this.albumId ? albums[this.albumId].sortName : "";
  this.genre = genres[this.genreId].name;

  fixSortName(this);
}

var Playlist = function(row) {
  for (idx in PlaylistIndices) {
    this[PlaylistIndices[idx]] = row[idx]
  }

  this.children = [];
}

var PlaylistTracks = function(row) {
  for (idx in PlaylistIndices) {
    this[PlaylistTracksIndices[idx]] = row[idx]
  }
}
