var PlaylistDisplayManager = function(playlistsHash, playlistTracks, tracksHash) {
  this.playlistsHash = playlistsHash;
  this.playlistTracks = playlistTracks;
  this.trackIdsArr = Object.keys(tracksHash);

  this.stopped = true;
  this.shownPlaylistId = null;
  this.nowPlayingPlaylistId = null;
  this.nowPlayingTrackId = null;
}

PlaylistDisplayManager.prototype.setCallbacks = function(filterTracksCallback, sortTracksCallback, displayedTracksChangedCallback, nowPlayingIdChangedCallback, nowPlayingTracksChangedCallback, clearFilterCallback) {
  this.filterTracksCallback = filterTracksCallback;
  this.sortTracksCallback = sortTracksCallback;
  this.displayedTracksChangedCallback = displayedTracksChangedCallback;
  this.nowPlayingIdChangedCallback = nowPlayingIdChangedCallback;
  this.nowPlayingTracksChangedCallback = nowPlayingTracksChangedCallback;
  this.clearFilterCallback = clearFilterCallback;
}

PlaylistDisplayManager.prototype.nowPlayingIdChanged = function(trackId) {
  this.stopped = false;
  this.nowPlayingTrackId = trackId;
  this.nowPlayingIdChangedCallback(trackId, this.shownPlaylistId == this.nowPlayingPlaylistId);
}

PlaylistDisplayManager.prototype.playlistChanged = function(playlistId) {
  if (playlistId == this.shownPlaylistId) { return; }
  this.shownPlaylistId = playlistId;
  if (this.stopped) { this.nowPlayingPlaylistId = this.shownPlaylistId; }

  var playlist = this.playlistsHash[playlistId];
  var tracks = [];

  if (playlist.isLibrary) {
    tracks = this.trackIdsArr;
  } else {
    var playlistTracks;
    if (playlist.children.length != 0) {
      tracks = this.accumulateFolderTracks(playlistId);
    } else {
      tracks = this.playlistTracks[playlist.id];
    }
  }

  this.tracksInShownPlaylist = tracks;
  this.clearFilterCallback();
  this.displayChanged();
}

PlaylistDisplayManager.prototype.displayChanged = function() {
  this.shownTracks = this.sortTracksCallback(this.filterTracksCallback(this.tracksInShownPlaylist.slice(0)));
  this.displayedTracksChangedCallback(this.shownTracks, this.nowPlayingPlaylistId == this.shownPlaylistId);

  if (this.shownPlaylistId == this.nowPlayingPlaylistId) {
    this.nowPlayingTracksChangedCallback(this.shownTracks, this.nowPlayingTrackId, false);
  }
}

PlaylistDisplayManager.prototype.accumulateFolderTracks = function(folderId) {
  var tracksHash = {}; // use a hash to prevent duplicates

  var addTracksToHash = function(tracks) {
    for (var i = 0; i < tracks.length; ++i) { tracksHash[tracks[i]] = 1; }
  };

  var accumulateFolderTracksStep = function(children) {
    for (var i = 0; i < children.length; ++i) {
      var playlist = children[i];
      if (this.playlistTracks[playlist.id]) { addTracksToHash(this.playlistTracks[playlist.id]); }
      accumulateFolderTracksStep(playlist.children);
    }
  }.bind(this);

  accumulateFolderTracksStep(this.playlistsHash[folderId].children);
  return Object.keys(tracksHash);
}

PlaylistDisplayManager.prototype.playTrack = function(trackId) {
  this.nowPlayingPlaylistId = this.shownPlaylistId;
  this.nowPlayingTracksChangedCallback(this.shownTracks, trackId, true);
}
