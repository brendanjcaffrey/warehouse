var Controls = function(settings) {
  var id = "#controls";
  $("<i class=\"icon ion-ios-rewind\" id=\"prev\"></i>").appendTo(id).click(this.prevClick.bind(this));
  $("<i class=\"icon ion-ios-play\" id=\"playpause\"></i>").appendTo(id).click(this.playPauseClick.bind(this));
  $("<i class=\"icon ion-ios-fastforward\" id=\"next\"></i>").appendTo(id).click(this.nextClick.bind(this));
  this.shuffle = $("<i class=\"icon ion-ios-shuffle\" id=\"shuffle\"></i>").appendTo(id).click(this.shuffleClick.bind(this));
  this.repeat = $("<i class=\"icon ion-ios-refresh\" id=\"repeat\"></i>").appendTo(id).click(this.repeatClick.bind(this));
  $("<input id=\"volume\" type=\"text\" />").appendTo(id);
  this.volume = $("#volume").slider({value: 50, max: 100}).on("slide", this.volumeChanged.bind(this));

  $("#playpause, #prev, #next").mousedown(function() { $(this).addClass("disabled"); });
  $("#playpause, #prev, #next").mouseup(function() { $(this).removeClass("disabled"); });
  $("#playpause, #prev, #next").mouseleave(function() { $(this).removeClass("disabled"); });

  this.settings = settings;

  this.updateShuffleDisplay();
  this.updateRepeatDisplay();
}

Controls.prototype.setCallbacks = function(prevCallback, playPauseCallback, nextCallback, shuffleChangedCallback, repeatChangedCallback, volumeChangedCallback) {
  this.prevCallback = prevCallback;
  this.playPauseCallback = playPauseCallback;
  this.nextCallback = nextCallback;
  this.shuffleChangedCallback = shuffleChangedCallback;
  this.repeatChangedCallback = repeatChangedCallback;
  this.volumeChangedCallback = volumeChangedCallback;
}

Controls.prototype.start = function() {
  this.shuffleChangedCallback(this.settings.getShuffle());
  this.repeatChangedCallback(this.settings.getRepeat());
  this.volumeChangedCallback(this.volume.slider("getValue"));
}

Controls.prototype.isPlayingChanged = function(playing) {
  if (playing) {
    $("#playpause").removeClass("ion-ios-play").addClass("ion-ios-pause");
  } else {
    $("#playpause").removeClass("ion-ios-pause").addClass("ion-ios-play");
  }
}

Controls.prototype.prevClick = function() {
  this.prevCallback();
}

Controls.prototype.playPauseClick = function() {
  this.playPauseCallback();
}

Controls.prototype.nextClick = function() {
  this.nextCallback();
}

Controls.prototype.shuffleClick = function() {
  this.settings.setShuffle(!this.settings.getShuffle());
  this.updateShuffleDisplay();
  this.shuffleChangedCallback(this.settings.getShuffle());
}

Controls.prototype.updateShuffleDisplay = function() {
  if (this.settings.getShuffle()) {
    this.shuffle.removeClass("disabled");
  } else {
    this.shuffle.addClass("disabled");
  }
}

Controls.prototype.repeatClick = function() {
  this.settings.setRepeat(!this.settings.getRepeat());
  this.updateRepeatDisplay();
  this.repeatChangedCallback(this.settings.getRepeat());
}

Controls.prototype.updateRepeatDisplay = function() {
  if (this.settings.getRepeat()) {
    this.repeat.removeClass("disabled");
  } else {
    this.repeat.addClass("disabled");
  }
}

Controls.prototype.volumeChanged = function(slider) {
  this.volumeChangedCallback(slider.value);
}

Controls.prototype.volumeUp = function() {
  value = this.volume.slider("getValue") + 10;
  if (value > 100) { value = 100; }
  this.volume.slider("setValue", value);
  this.volumeChangedCallback(value);
}

Controls.prototype.volumeDown = function() {
  value = this.volume.slider("getValue") - 10;
  if (value < 0) { value = 0; }
  this.volume.slider("setValue", value);
  this.volumeChangedCallback(value);
}
