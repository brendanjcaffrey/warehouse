var Audio = function(numSlots, trackChanges) {
  this.numSlots = numSlots;
  this.trackChanges = trackChanges;
  this.audios = []; this.tracks = [];
  var container = $("#progress");
  this.currentTimeDisplay = $('<div id="current-time"></div>').appendTo(container);
  this.infoContainer = $('<div id="info-container"></div>').appendTo(container);
  var nameContainer = $('<div id="name"></div>').appendTo(this.infoContainer);
  this.nameDisplay = $('<span></span>').appendTo(nameContainer);
  this.returnButton = $("<i class=\"icon ion-ios-return-left\" id=\"return\"></i>").appendTo(nameContainer).click(this.returnClick.bind(this));
  var artistAlbumDisplay = $('<div id="artist-album"></div>').appendTo(this.infoContainer);
  this.artistDisplay = $('<span></span>').appendTo(artistAlbumDisplay);
  this.dashDisplay = $('<span> &ndash; </span>').appendTo(artistAlbumDisplay);
  this.albumDisplay = $('<span></span>').appendTo(artistAlbumDisplay);
  this.remainingTimeDisplay = $('<div id="remaining-time"></div>').appendTo(container);
  this.progress = $('<div class="progress"></div>').appendTo(container);
  this.progressBar = $('<div class="progress-bar"></div>').appendTo(this.progress);
  this.progress.click(this.progressBarClick.bind(this));

  for (var i = 0; i < this.numSlots; ++i) {
    this.audios.push(document.getElementById("audio" + i));
    this.tracks.push(null);
    this.audios[i].addEventListener("timeupdate", () => this.currentTimeUpdated());
  }

  this.nowPlayingSlot = 0;
  this.currentVolume = 0;

  $("#return").mousedown(function() { $(this).addClass("disabled"); });
  $("#return").mouseup(function() { $(this).removeClass("disabled"); });
  $("#return").mouseleave(function() { $(this).removeClass("disabled"); });
}

Audio.prototype.setCallbacks = function(trackFinishedCallback, showNowPlayingTrackCallback) {
  this.trackFinishedCallback = trackFinishedCallback;
  this.showNowPlayingTrackCallback = showNowPlayingTrackCallback;
}

Audio.prototype.loadTracks = function(tracksArr, startPlayingFirst) {
  var returnId = (val) => val.id;
  if (tracksArr.length < 1) { return; }

  this.updateInfoDisplay(this.nameDisplay, this.infoContainer, tracksArr[0].name);
  this.artistDisplay.text(tracksArr[0].artist);
  this.albumDisplay.text(tracksArr[0].album);
  if (tracksArr[0].album.length == 0) { this.dashDisplay.hide(); } else { this.dashDisplay.show(); }

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

Audio.prototype.formatTime = function(seconds) {
  var integerSeconds = Math.round(seconds);
  var minutes = Math.floor(seconds / 60);
  var seconds = Math.floor(integerSeconds - (minutes * 60));
  return String(minutes) + ":" + (seconds < 10 ? "0" : "") + String(seconds);
}

Audio.prototype.currentTimeUpdated = function() {
  var audio = this.audios[this.nowPlayingSlot];
  var track = this.tracks[this.nowPlayingSlot];

  var percent = (audio.currentTime - track.start) / (track.finish - track.start);
  this.progressBar.css("width", String(percent * 100) + "%");

  this.currentTimeDisplay.text(this.formatTime(audio.currentTime));
  this.remainingTimeDisplay.text("-" + this.formatTime(track.finish - audio.currentTime));

  if (audio.currentTime >= audio.duration || audio.currentTime >= track.finish) {
    if (this.trackChanges) { $.post('/play/' + track.id); }
    ++track.playCount;
    this.trackFinishedCallback();
  }
}

Audio.prototype.progressBarClick = function(e) {
  var audio = this.audios[this.nowPlayingSlot];
  var track = this.tracks[this.nowPlayingSlot];

  var percentage = e.offsetX / $(e.currentTarget).width();
  var add = (track.finish - track.start) * percentage;
  var time = track.start + add;
  audio.currentTime = time;
}

Audio.prototype.returnClick = function(slider) {
  this.showNowPlayingTrackCallback();
}

Audio.prototype.updateInfoDisplay = function(out, container, value) {
  out.text(value);

  // insert an ellipsis in the middle if text is bigger than the container
  var halfValueLength = Math.floor(value.length / 2);
  var removeFromEachHalf = 0;
  while (out.width() > container.width())
  {
    removeFromEachHalf += 1;
    out.text(value.substring(0, halfValueLength - removeFromEachHalf) + "..." + value.substring(halfValueLength + removeFromEachHalf));
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
