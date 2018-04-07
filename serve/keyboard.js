var Keyboard = function() {
  this.letterPressString = "";
  this.letterPressTimeoutID = null;

  $(document).bind("keydown", "left", this.leftPress.bind(this));
  $(document).bind("keydown", "space", this.spacePress.bind(this));
  $(document).bind("keydown", "right", this.rightPress.bind(this));
  $(document).bind("keydown", "ctrl+up", this.ctrlUpPress.bind(this));
  $(document).bind("keydown", "ctrl+down", this.ctrlDownPress.bind(this));

  var alphabet = "abcdefghijklmnopqrstuvwxyz0123456789.()-'".split("");
  $.each(alphabet, (i, e) => $(document).bind("keydown", alphabet[i], this.letterPressEvent.bind({ keyboard: this, letter: alphabet[i] })));

  // this is how the chrome extension communicates with the web app
  window.addEventListener("message", this.extensionMessage.bind(this), false);
}

Keyboard.prototype.setCallbacks = function(prevCallback, playPauseCallback, nextCallback, volumeUpCallback, volumeDownCallback, typeToShowCallback) {
  this.prevCallback = prevCallback;
  this.playPauseCallback = playPauseCallback;
  this.nextCallback = nextCallback;
  this.volumeUpCallback = volumeUpCallback;
  this.volumeDownCallback = volumeDownCallback;
  this.typeToShowCallback = typeToShowCallback;
}

Keyboard.prototype.leftPress = function(e) {
  this.prevCallback();
  return false;
}

Keyboard.prototype.spacePress = function(e) {
  if (this.letterPressTimeoutID != null) { this.letterPress(' '); }
  else { this.playPauseCallback(); }
  return false;
}

Keyboard.prototype.rightPress = function(e) {
  this.nextCallback();
  return false;
}

Keyboard.prototype.ctrlUpPress = function(e) {
  this.volumeUpCallback();
  return false;
}

Keyboard.prototype.ctrlDownPress = function(e) {
  this.volumeDownCallback();
  return false;
}

Keyboard.prototype.letterPressEvent = function(e) {
  this.keyboard.letterPress(this.letter);
}

Keyboard.prototype.letterPress = function(letter) {
  this.letterPressString += letter;

  if (this.letterPressTimeoutID != null) {
    window.clearTimeout(this.letterPressTimeoutID);
    this.letterPressTimeoutID = null;
  }

  this.letterPressTimeoutID = window.setTimeout(this.letterPressTimedOut.bind(this), 750);
}

Keyboard.prototype.letterPressTimedOut = function() {
  this.typeToShowCallback(this.letterPressString);
  this.letterPressString = "";
  this.letterPressTimeoutID = null;
}

Keyboard.prototype.extensionMessage = function(e) {
  if (event.data.source != "itunes-streamer") { return; }

  switch (e.data.type) {
    case "prev":        this.prevCallback(); break;
    case "play-pause":  this.playPauseCallback(); break;
    case "next":        this.nextCallback(); break;
    case "volume-up":   this.volumeUpCallback(); break;
    case "volume-down": this.volumeDownCallback(); break;
  }
}
