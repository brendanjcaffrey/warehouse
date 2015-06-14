var Audio = function(streamer) {
  this.audios = [document.getElementById("audio1"),
                 document.getElementById("audio2")];
  this.tracks = [null, null];
  this.count = this.audios.length
  this.nowPlayingSlot = 0;
  this.streamer = streamer;

  var self = this;
  for (var i = 0; i < this.count; i++) {
    this.audios[i].addEventListener("timeupdate", function() { self.currentTimeUpdated() });
  }
}

Audio.prototype.currentTimeUpdated = function() {
  var audio = this.audios[this.nowPlayingSlot];
  var track = this.tracks[this.nowPlayingSlot];

  if (audio.currentTime >= audio.duration || audio.currentTime >= audio.finish) {
    $.post('/play/' + track.id + '.' + track.ext);
    this.streamer.next();
  }
}

Audio.prototype.getNonPlayingSlot = function() {
  return (this.nowPlayingSlot+1) % this.count;
}

Audio.prototype.loadIntoSlot = function(track, slot) {
  this.tracks[slot] = track;

  var audio = $(this.audios[slot]);
  // setting #t=123 at the end of the URL sets the start time cross browser
  audio.attr("src", "/tracks/" + String(track.id) + "." + track.ext + "#t=" + String(track.start));
  audio.attr("type", ext_to_type(track.ext));
  audio.attr("data-track-id", String(track.id));
  audio.currentTime = track.start;
}

Audio.prototype.preload = function(track) {
  this.loadIntoSlot(track, this.getNonPlayingSlot());
}

Audio.prototype.load = function(track) {
  if ($(this.audios[this.nowPlayingSlot]).attr("data-track-id") == String(track.id)) {
    // nop
  } else if ($(this.audios[this.getNonPlayingSlot()]).attr("data-track-id") == String(track.id)) {
    this.pause();
    this.nowPlayingSlot = this.getNonPlayingSlot();
  } else {
    this.loadIntoSlot(track, this.nowPlayingSlot);
  }

  this.play();
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

  this.audios[this.nowPlayingSlot].currentTime = this.tracks[this.nowPlayingSlot].start;
  return true;
}

Audio.prototype.getNowPlayingTrackId = function() {
  if (!this.tracks[this.nowPlayingSlot]) return -1;
  return this.tracks[this.nowPlayingSlot].id;
}
