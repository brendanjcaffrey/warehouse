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
    case 'mp3': return 'audio/mpeg';
    case 'mp4': return 'audio/mp4';
    case 'm4a': return 'audio/mp4';
    case 'aif': return 'audio/aif';
    case 'aiff': return 'audio/aif';
    case 'wav': return 'audio/wav';
  }
}

var GenreIndices = ["id", "name"];
var ArtistIndices = ["id", "name", "sortName"];
var AlbumIndices = ["id", "artistId", "name", "sortName"];
var TrackIndices = ["id", "name", "sortName", "artistId", "albumId", "genreId",
                    "duration", "start", "finish", "track", "trackCount", "disc",
                    "discCount", "playCount", "ext"];
var PlaylistIndices = ["id", "name", "parentId", "isLibrary"];

var Genre = function(row) {
  for (index in GenreIndices) {
    this[GenreIndices[index]] = row[index];
  }
}

var Artist = function(row) {
  for (index in ArtistIndices) {
    this[ArtistIndices[index]] = row[index];
  }

  fixSortName(this);
}

var Album = function(row) {
  for (index in AlbumIndices) {
    this[AlbumIndices[index]] = row[index];
  }

  fixSortName(this);
}

var Track = function(row, artists, albums, genres) {
  for (index in TrackIndices) {
    this[TrackIndices[index]] = row[index]
  }

  this.time = secondsToTime(this.duration);
  this.artist = artists[this.artistId].name;
  this.sortArtist = artists[this.artistId].sortName;
  this.album = albums[this.albumId].name;
  this.sortAlbum = albums[this.albumId].sortName;
  this.genre = genres[this.genreId].name;

  fixSortName(this);
  this.searchName = this.sortName.toLowerCase();
}

var Playlist = function(row) {
  for (index in PlaylistIndices) {
    this[PlaylistIndices[index]] = row[index]
  }

  this.children = [];
}

var ResolvePlaylistTree = function(playlists) {
  var sortName = function(i1, i2) {
    if (i1.isLibrary) { return -1; }
    else if (i2.isLibrary) { return 1; }

    if (i1.name == i2.name) { return 0; }
    else if (i1.name > i2.name) { return 1; }
    else { return -1; }
  }

  var ResolvePlaylistTreeStep = function(playlists, tree, parentId) {
    for (var i = 0; i < playlists.length; ++i) {
      if (playlists[i].parentId == parentId) {
        tree.push(playlists[i]);
        ResolvePlaylistTreeStep(playlists, playlists[i].children, playlists[i].id);
      }
    }
    tree.sort(sortName);
  }

  tree = [];
  ResolvePlaylistTreeStep(playlists, tree, -1);

  return tree;
}
