var RemoteControl = function(id, settings) {
  this.id = id;
  this.settings = settings;
  this.connected = false;
  this.websocket = null;

  this.address = $("<input type=\"text\" id=\"address\" class=\"form-control\" placeholder=\"localhost:9292\" />").appendTo(id);
  this.address.val(this.settings.getRemoteAddress());
  this.address.on('input', this.saveAddressValue.bind(this));

  var span = $("<span class=\"input-group-btn\"></span>").appendTo(id);
  this.button = $("<input type=\"button\" value=\"Connect\" class=\"btn btn-success\" />").appendTo(span);
  this.button.click(this.connectButtonClick.bind(this));
}

RemoteControl.prototype.setCallbacks = function(prevCallback, playPauseCallback, nextCallback) {
  this.prevCallback = prevCallback;
  this.playPauseCallback = playPauseCallback;
  this.nextCallback = nextCallback;
}

RemoteControl.prototype.saveAddressValue = function() {
  this.settings.setRemoteAddress(this.address.val());
}

RemoteControl.prototype.connectButtonClick = function() {
  if (this.connected) {
    if (this.websocket && this.websocket.readyState == 1) { // calling close() raises an error unless the socket is open
      this.websocket.onclose = function() {}; // have to prevent the handler from firing
      this.websocket.close();
    }
    this.websocket = null;
    this.connected = false;
    this.button.val("Connect").removeClass("btn-danger").addClass("btn-success");
  } else {
    this.connected = true;
    this.button.val("Disconnect").removeClass("btn-success").addClass("btn-danger");

    this.websocket = new WebSocket("ws://" + this.address.val() + "/");
    this.websocket.onmessage = this.handleMessage.bind(this);
    this.websocket.onclose = this.connectButtonClick.bind(this);
  }
}

RemoteControl.prototype.handleMessage = function(event) {
  if (event.data == "playpause") { streamer.controls.playPauseCallback(); }
  else if (event.data == "next") { streamer.controls.nextCallback(); }
  else if (event.data == "prev") { streamer.controls.prevCallback(); }
  else if (event.data == "heartbeat") { /* nop */ }
  else { console.log("Unknown websocket event"); console.log(event); }
}
