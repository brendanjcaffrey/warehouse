var PlaylistControlManager = function(tracksHash, numAudioSlots) {
  this.tracksHash = tracksHash;
  this.numAudioSlots = numAudioSlots;

  this.stopped = true;
  this.playing = false;
  this.shuffle = false;
  this.repeat = false;
  this.nowPlayingTrackId = null;
}

PlaylistControlManager.prototype.setCallbacks = function(nowPlayingIdChangedCallback, isPlayingChangedCallback, loadTracksCallback, playCallback, pauseCallback, rewindCurrentTrackCallback) {
  this.nowPlayingIdChangedCallback = nowPlayingIdChangedCallback;
  this.isPlayingChangedCallback = isPlayingChangedCallback;
  this.loadTracksCallback = loadTracksCallback;
  this.playCallback = playCallback;
  this.pauseCallback = pauseCallback;
  this.rewindCurrentTrackCallback = rewindCurrentTrackCallback;
}

PlaylistControlManager.prototype.nowPlayingTracksChanged = function(orderedTracks, newTrackId) {
  this.orderedPlayingTracks = orderedTracks.slice(0);
  this.generateShuffledPlaylist();

  if (this.stopped && newTrackId != null) {
    this.stopped = false;
    this.playing = true;
    this.isPlayingChangedCallback(this.playing);
  }

  this.hiddenPlayingTrackId = null;
  this.playlistIndex = this.getCurrentList().indexOf(newTrackId);
  if (this.stopped) {
    this.playlistIndex = 0;
  } else if (this.playlistIndex == -1) {
    console.assert(newTrackId != null);
    this.hiddenPlayingTrackId = newTrackId;
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
  var tracksToLoad = []; var i;
  var currentList = this.getCurrentList();
  var currentListLength = currentList.length;

  // if we're searching, then the currently playing track won't be in the playlist and we don't want to overwrite it
  if (this.playlistIndex == -1) {
    console.assert(this.hiddenPlayingTrackId != null);
    tracksToLoad.push(this.tracksHash[this.hiddenPlayingTrackId]);
    i = 0;
    ++currentListLength;
  } else {
    i = -1;
  }

  while (tracksToLoad.length < this.numAudioSlots && ++i < currentListLength)
  {
    var playlistIndex = (this.playlistIndex + i) % currentList.length;
    tracksToLoad.push(this.tracksHash[currentList[playlistIndex]]);
  }

  this.nowPlayingId = tracksToLoad[0].id;
  this.loadTracksCallback(tracksToLoad, this.playing);
  if (!this.stopped) { this.nowPlayingIdChangedCallback(this.nowPlayingId); }
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
  return this.repeat || (this.orderedPlayingTracks.length == 1 && this.playlistIndex == 0);
}

PlaylistControlManager.prototype.prev = function() {
  if (this.shouldRewind()) { return this.rewindCurrentTrackCallback(); }

  this.playlistIndex--;
  if (this.playlistIndex < 0) { this.playlistIndex = this.getCurrentList().length-1; }

  this.pushNextTracks();
}

PlaylistControlManager.prototype.playPause = function() {
  this.playing = !this.playing;
  this.isPlayingChangedCallback(this.playing);

  if (this.stopped) { this.stopped = false; }
  if (this.playing) { this.nowPlayingIdChangedCallback(this.getCurrentList()[this.playlistIndex]); }

  if (this.playing) { this.playCallback(); }
  else { this.pauseCallback(); }
}

PlaylistControlManager.prototype.next = function() {
  if (this.shouldRewind()) { return this.rewindCurrentTrackCallback(); }

  this.playlistIndex += 1;
  if (this.playlistIndex >= this.getCurrentList().length) { this.playlistIndex = 0; }

  this.pushNextTracks();
}
