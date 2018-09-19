var PlaylistControlManager = function(tracksHash, numAudioSlots) {
  this.tracksHash = tracksHash;
  this.numAudioSlots = numAudioSlots;

  this.stopped = true;
  this.playing = false;
  this.shuffle = false;
  this.repeat = false;
  this.nowPlayingTrackId = null;
  this.inPlayNextList = false;
  this.playNextList = [];
  this.shownPlaylistId = null;
}

PlaylistControlManager.prototype.setCallbacks = function(nowPlayingIdChangedCallback, overrideNowPlayingPlaylistChanged, isPlayingChangedCallback, loadTracksCallback, playCallback, pauseCallback, rewindCurrentTrackCallback) {
  this.nowPlayingIdChangedCallback = nowPlayingIdChangedCallback;
  this.overrideNowPlayingPlaylistChanged = overrideNowPlayingPlaylistChanged;
  this.isPlayingChangedCallback = isPlayingChangedCallback;
  this.loadTracksCallback = loadTracksCallback;
  this.playCallback = playCallback;
  this.pauseCallback = pauseCallback;
  this.rewindCurrentTrackCallback = rewindCurrentTrackCallback;
}

PlaylistControlManager.prototype.shownPlaylistChanged = function(playlistId) {
  this.shownPlaylistId = playlistId;
}

PlaylistControlManager.prototype.nowPlayingTracksChanged = function(orderedTracks, newTrackId, isForcedPlay) {
  this.orderedPlayingTracks = orderedTracks.slice(0);
  this.generateShuffledPlaylist();

  if (newTrackId != null && isForcedPlay) {
    this.stopped = false;
    this.playing = true;
    this.isPlayingChangedCallback(this.playing);
    this.playNextList = [];
  }

  this.hiddenPlayingTrackId = null;
  if (!this.inPlayNextList) {
    this.playlistIndex = this.getCurrentList().indexOf(newTrackId);
    if (this.stopped) {
      this.playlistIndex = 0;
    } else if (this.playlistIndex == -1) {
      if (newTrackId == null) { return; } // only happens when you load the app, go to an empty playlist, press play and then go to another empty playlist
      this.hiddenPlayingTrackId = newTrackId;
    }
  }

  this.pushNextTracks();
}

PlaylistControlManager.prototype.getCurrentList = function() {
  return this.shuffle ? this.shuffledPlayingTracks : this.orderedPlayingTracks;
}

PlaylistControlManager.prototype.generateShuffledPlaylist = function() {
  this.shuffledPlayingTracks = this.orderedPlayingTracks.slice(0);
  // from http://stackoverflow.com/questions/6274339/how-can-i-shuffle-an-array-in-javascript
  for (var j, x, i = this.shuffledPlayingTracks.length; i; j = Math.floor(Math.random() * i), x = this.shuffledPlayingTracks[--i],
    this.shuffledPlayingTracks[i] = this.shuffledPlayingTracks[j], this.shuffledPlayingTracks[j] = x);
}

PlaylistControlManager.prototype.pushNextTracks = function() {
  var tracksToLoad = [];
  var currentList = this.getCurrentList();
  var currentListLength = currentList.length;

  // if we're searching, then the currently playing track won't be in the playlist and we don't want to overwrite it
  if (this.playlistIndex == -1 && !this.inPlayNextList) {
    if (this.hiddenPlayingTrackId == null) { return; } // only happens when you load the app, navigate to an empty playlist, click play, then click previous track
    tracksToLoad.push(this.hiddenPlayingTrackId);
  }

  var realPlaylistIndex = Math.max(0, this.playlistIndex);
  var playlistIndexOffset = -1;
  if (!this.inPlayNextList) {
    tracksToLoad.push(currentList[realPlaylistIndex]);
    ++playlistIndexOffset;
  }

  var playNextLength = Math.min(this.numAudioSlots - tracksToLoad.length, this.playNextList.length);
  tracksToLoad = tracksToLoad.concat(this.playNextList.slice(0, playNextLength).map(obj => obj.id));

  while (tracksToLoad.length < this.numAudioSlots && ++playlistIndexOffset < currentListLength)
  {
    var playlistIndex = (realPlaylistIndex + playlistIndexOffset) % currentList.length;
    tracksToLoad.push(currentList[playlistIndex]);
  }

  tracksToLoad = tracksToLoad.map(trackId => this.tracksHash[trackId]);

  if (tracksToLoad.length == 0) { return; }
  this.nowPlayingId = tracksToLoad[0].id;
  this.loadTracksCallback(tracksToLoad, this.playing);
  if (!this.stopped) { this.nowPlayingIdChangedCallback(this.nowPlayingId); }
}

PlaylistControlManager.prototype.playTrackNext = function(trackId) {
  this.playNextList.push({ id: trackId, playlistId: this.shownPlaylistId });
  this.pushNextTracks();
}

PlaylistControlManager.prototype.shuffleChanged = function(shuffle) {
  this.shuffle = shuffle;
  if (!this.stopped) {
    this.playlistIndex = this.getCurrentList().indexOf(this.nowPlayingId);
  }
  this.pushNextTracks();
}

PlaylistControlManager.prototype.repeatChanged = function(repeat) {
  this.repeat = repeat;
}

PlaylistControlManager.prototype.shouldRewind = function() {
  return this.repeat || (this.orderedPlayingTracks.length == 1 && this.playlistIndex == 0 && this.playNextList.length == 0);
}

PlaylistControlManager.prototype.prev = function() {
  if (this.getCurrentList().length == 0 && this.stopped) { return; }
  if (this.shouldRewind()) { return this.rewindCurrentTrackCallback(); }

  this.playlistIndex--;
  if (this.playlistIndex < 0) { this.playlistIndex = this.getCurrentList().length-1; }

  this.pushNextTracks();
}

PlaylistControlManager.prototype.playPause = function() {
  this.playing = !this.playing;
  this.isPlayingChangedCallback(this.playing);

  if (this.stopped) { this.stopped = false; }
  if (this.playing && this.getCurrentList().length != 0) { this.nowPlayingIdChangedCallback(this.getCurrentList()[this.playlistIndex]); }

  if (this.playing) { this.playCallback(); }
  else { this.pauseCallback(); }
}

PlaylistControlManager.prototype.next = function() {
  if (this.getCurrentList().length == 0 && this.playNextList.length == 0 && this.stopped) { return; }
  if (this.shouldRewind()) { return this.rewindCurrentTrackCallback(); }

  var oldPlayNextLength = this.playNextList.length;
  if (!this.inPlayNextList) {
    this.playlistIndex += 1;
    if (this.playlistIndex >= this.getCurrentList().length) { this.playlistIndex = 0; }
  } else {
    this.playNextList.shift();
  }

  if (this.playNextList.length == 0) {
    this.inPlayNextList = false;
    if (oldPlayNextLength != 0) { this.hiddenPlayingTrackId = null; }
  } else {
    this.inPlayNextList = true;
  }

  this.overrideNowPlayingPlaylistChanged(this.inPlayNextList ? this.playNextList[0].playlistId : null);
  this.pushNextTracks();
}
