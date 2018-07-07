var Audio = function(numSlots) {
  this.numSlots = numSlots;
  this.audios = []; this.tracks = [];
  this.progress = $('<div class="progress"></div>').appendTo($("#progress"));
  this.progressBar = $('<div class="progress-bar"></div>').appendTo(this.progress);

  for (var i = 0; i < this.numSlots; ++i) {
    this.audios.push(document.getElementById("audio" + i));
    this.tracks.push(null);
    this.audios[i].addEventListener("timeupdate", () => this.currentTimeUpdated());
  }

  this.nowPlayingSlot = 0;
  this.currentVolume = 0;
}

Audio.prototype.setCallbacks = function(trackFinishedCallback) {
  this.trackFinishedCallback = trackFinishedCallback;
}

Audio.prototype.loadTracks = function(tracksArr, startPlayingFirst) {
  var returnId = (val) => val.id;
  if (tracksArr.length < 1) { return; }

  // find the intersection of what we have and what we want
  loadedIds = this.tracks.filter((el) => el != null).map(returnId);
  wantLoadedIds = tracksArr.map(returnId);
  intersection = loadedIds.filter((n) => wantLoadedIds.indexOf(n) != -1);
  intersectionCount = intersection.length;

  // find which slots don't have something we want in them
  allSlots = []; for (var i = 0; i < this.numSlots; ++i) { allSlots.push(i); }
  freeSlots = allSlots.filter((idx) => this.tracks[idx] == null || intersection.indexOf(this.tracks[idx].id) == -1);

  // find which tracks we don't already have loaded
  needsLoading = tracksArr.filter((track) => intersection.indexOf(track.id) == -1);
  console.assert(freeSlots.length >= needsLoading.length);

  // load them
  for (var i = 0; i < needsLoading.length; ++i) { this.loadIntoSlot(needsLoading[i], freeSlots[i]); }

  // find the now playing spot, pause and rewind all other ones
  for (var i = 0; i < this.numSlots; ++i) {
    if (this.tracks[i] == null) { /* nop */ }
    else if (this.tracks[i].id == tracksArr[0].id) {
      this.nowPlayingSlot = i;
      if (startPlayingFirst) { this.audios[i].play(); }
    } else { this.audios[i].pause(); this.rewindTrackInSlot(i); }
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

Audio.prototype.rewindTrackInSlot = function(slot) {
  this.audios[slot].currentTime = this.tracks[slot].start;
}

Audio.prototype.currentTimeUpdated = function() {
  var audio = this.audios[this.nowPlayingSlot];
  var track = this.tracks[this.nowPlayingSlot];

  var percent = (audio.currentTime - track.start) / (track.finish - track.start);
  this.progressBar.css("width", String(percent * 100) + "%");

  if (audio.currentTime >= audio.duration || audio.currentTime >= track.finish) {
    $.post('/play/' + track.id);
    this.trackFinishedCallback();
  }
}

Audio.prototype.volumeChanged = function(intVal) {
  this.currentVolume = intVal;
  var floatVal = intVal / 100.0;

  for (var idx in this.audios) {
    this.audios[idx].volume = floatVal;
  }
}

Audio.prototype.play = function(value) {
  if (!this.tracks[this.nowPlayingSlot]) return false;
  this.audios[this.nowPlayingSlot].play();
}

Audio.prototype.pause = function(value) {
  if (!this.tracks[this.nowPlayingSlot]) return false;
  this.audios[this.nowPlayingSlot].pause();
}

Audio.prototype.rewindCurrentTrack = function(value) {
  if (!this.tracks[this.nowPlayingSlot]) return false;
  this.audios[this.nowPlayingSlot].currentTime = this.tracks[this.nowPlayingSlot].start;
}
