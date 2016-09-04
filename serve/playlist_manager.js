var PlaylistManager = function(audio, settings, tracksHash) {
  this.audio = audio;
  this.settings = settings;
  this.tracksHash = tracksHash;

  this.playlist = [];
  this.playlistIndex = 0;
}

PlaylistManager.prototype.shufflePlaylist = function() {
  // from http://stackoverflow.com/questions/6274339/how-can-i-shuffle-an-array-in-javascript
  for (var j, x, i = this.playlist.length; i; j = Math.floor(Math.random() * i),
    x = this.playlist[--i], this.playlist[i] = this.playlist[j], this.playlist[j] = x);
}

PlaylistManager.prototype.rebuild = function(stopped, nowPlayingId, api) {
  if (api) { this.api = api }
  this.playlist = this.api.rows({search: "applied"}).data().map(function (x) { return x.id });

  if (nowPlayingId >= 0) {
    // if the current song isn't in the results, then this will return -1,
    // which means the next song to be played will be index 0 which is what we want
    this.playlistIndex = this.playlist.indexOf(nowPlayingId);
    if (this.playlistIndex == -1) { this.hiddenPlayingTrackId = nowPlayingId; }
  } else {
    this.playlistIndex = 0;
  }

  if (this.settings.getShuffle()) {
    var saveFirstTrack = this.playlistIndex >= 0 && !stopped;
    // pull out the currently playing track
    if (saveFirstTrack) { this.playlist.splice(this.playlistIndex, 1); }
    this.shufflePlaylist();

    // and add it back at the beginning
    if (saveFirstTrack) {
      this.playlist.unshift(nowPlayingId);
      this.playlistIndex = 0;
    }
  }

  this.onUpdate(nowPlayingId);
}

PlaylistManager.prototype.getCurrentTrackId = function() {
  if (this.playlistIndex == -1) { return this.hiddenPlayingTrackId; }
  return this.playlist[this.playlistIndex];
}

PlaylistManager.prototype.moveBack = function() {
  this.playlistIndex--;
  if (this.playlistIndex < 0) { this.playlistIndex = this.playlist.length - 1; }

  this.onUpdate(-1);
}

PlaylistManager.prototype.moveForward = function() {
  this.playlistIndex += 1;
  if (this.playlistIndex >= this.playlist.length) { this.playlistIndex = 0; }

  this.onUpdate(-1);
}

PlaylistManager.prototype.onUpdate = function(nowPlayingId) {
  var tracksToLoad = []; var i;

  // if we're searching, then the currently playing track won't be in the playlist and we don't want to overwrite it
  if (this.playlistIndex == -1) {
    console.assert(nowPlayingId != -1);
    tracksToLoad.push(this.tracksHash[nowPlayingId]);
    i = 0;
  } else {
    i = -1;
  }

  while (tracksToLoad.length < this.audio.numSlots && ++i < this.playlist.length)
  {
    var playlistIndex = (this.playlistIndex + i) % this.playlist.length;
    tracksToLoad.push(this.tracksHash[this.playlist[playlistIndex]]);
  }

  this.audio.loadTracks(tracksToLoad);
}
