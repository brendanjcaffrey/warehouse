var Audio = function(streamer) {
  this.numSlots = 3; var self = this;
  this.audios = []; this.tracks = [];

  for (var i = 0; i < this.numSlots; ++i) {
    this.audios.push(document.getElementById("audio" + (i+1)));
    this.tracks.push(null);
    this.audios[i].addEventListener("timeupdate", function() { self.currentTimeUpdated() });
  }

  this.nowPlayingSlot = 0;
  this.streamer = streamer;
  this.currentVolume = 0;
}

Audio.prototype.currentTimeUpdated = function() {
  var audio = this.audios[this.nowPlayingSlot];
  var track = this.tracks[this.nowPlayingSlot];

  if (audio.currentTime >= audio.duration || audio.currentTime >= track.finish) {
    $.post('/play/' + track.id);
    this.streamer.next();
  }
}

Audio.prototype.loadIntoSlot = function(track, slot) {
  this.tracks[slot] = track;

  var audio = $(this.audios[slot]);
  // setting #t=123 at the end of the URL sets the start time cross browser
  audio.attr("src", "/tracks/" + String(track.id) + "#t=" + String(track.start));
  audio.attr("type", extToType(track.ext));
  audio.attr("data-track-id", String(track.id));
  audio.currentTime = track.start;
}

Audio.prototype.loadTracks = function(tracksArr) {
  var self = this; var returnId = function(val) { return val.id; };
  if (tracksArr.length < 1) { return; }

  // find the intersection of what we have and what we want
  loadedIds = this.tracks.filter(function(el) { return el != null; }).map(returnId);
  wantLoadedIds = tracksArr.map(returnId);
  intersection = loadedIds.filter(function(n) { return wantLoadedIds.indexOf(n) != -1 });
  intersectionCount = intersection.length;

  // find which slots don't have something we want in them
  allSlots = []; for (var i = 0; i < this.numSlots; ++i) { allSlots.push(i); }
  freeSlots = allSlots.filter(function(idx) {
    return self.tracks[idx] == null || intersection.indexOf(self.tracks[idx].id) == -1
  });

  // find which tracks we don't already have loaded
  needsLoading = tracksArr.filter(function(track) { return intersection.indexOf(track.id) == -1; });
  console.assert(freeSlots.length >= needsLoading.length);

  // load them
  for (var i = 0; i < needsLoading.length; ++i) { this.loadIntoSlot(needsLoading[i], freeSlots[i]); }

  // find the now playing spot, pause and rewind all other ones
  for (var i = 0; i < this.numSlots; ++i) {
    if (this.tracks[i].id == tracksArr[0].id) { this.nowPlayingSlot = i; }
    else { this.audios[i].pause(); this.rewindTrackInSlot(i); }
  }
}

Audio.prototype.play = function() {
  if (!this.tracks[this.nowPlayingSlot]) return false;
  this.audios[this.nowPlayingSlot].play();
}

Audio.prototype.pause = function() {
  if (!this.tracks[this.nowPlayingSlot]) return false;
  this.audios[this.nowPlayingSlot].pause();
}

Audio.prototype.tryRewind = function() {
  if (!this.tracks[this.nowPlayingSlot]) return false;

  this.rewindTrackInSlot(this.nowPlayingSlot);
  return true;
}

Audio.prototype.rewindTrackInSlot = function(slot) {
  this.audios[slot].currentTime = this.tracks[slot].start;
}

Audio.prototype.getNowPlayingTrackId = function() {
  if (!this.tracks[this.nowPlayingSlot]) { return null; }
  return this.tracks[this.nowPlayingSlot].id;
}

Audio.prototype.updateAllVolumes = function(intVal) {
  this.currentVolume = intVal;
  floatVal = intVal / 100.0;

  for (var i = 0; i < this.numSlots; ++i) {
    this.audios[i].volume = floatVal;
  }
}
