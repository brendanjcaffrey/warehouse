var RemoteControl = function(settings) {
  this.id = "#remote-control";
  this.settings = settings;
  this.connected = false;
  this.websocket = null;

  this.div = $("<div class=\"input-group input-group-sm\"></div>").appendTo(this.id);

  this.address = $("<input type=\"text\" id=\"address\" class=\"form-control\" placeholder=\"localhost:9292\" />").appendTo(this.div);
  this.address.val(this.settings.getRemoteAddress());
  this.address.on('input', this.addressChanged.bind(this));

  span = $("<span class=\"input-group-btn\"></span>").appendTo(this.div);
  this.button = $("<input type=\"button\" value=\"Connect\" class=\"btn btn-success\" />").appendTo(span);
  this.button.click(this.connectButtonClick.bind(this));
  this.addressChanged();

  this.success = $("<span class=\"icon ion-ios-checkmark form-control-feedback\"></span>").appendTo(this.id);
  this.failure = $("<span class=\"icon ion-ios-close form-control-feedback\"></span>").appendTo(this.id);
  this.success.hide(); this.failure.hide();

  if (this.settings.getRemoteAddress() != "") { this.button.click(); }
}

RemoteControl.prototype.setCallbacks = function(prevCallback, playPauseCallback, nextCallback) {
  this.prevCallback = prevCallback;
  this.playPauseCallback = playPauseCallback;
  this.nextCallback = nextCallback;
}

RemoteControl.prototype.addressChanged = function() {
  this.settings.setRemoteAddress(this.address.val());

  if (this.address.val().length == 0) { this.button.attr("disabled", "disabled"); }
  else { this.button.removeAttr("disabled"); }
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
    this.failure.show(); this.success.hide();
    $(this.id).removeClass("has-success").addClass("has-error");
  } else {
    this.connected = true;
    this.button.val("Disconnect").removeClass("btn-success").addClass("btn-danger");
    this.success.show(); this.failure.hide();
    $(this.id).removeClass("has-error").addClass("has-success");

    this.websocket = new WebSocket("ws://" + this.address.val() + "/");
    this.websocket.onmessage = this.handleMessage.bind(this);
    this.websocket.onclose = this.connectButtonClick.bind(this);
  }
}

RemoteControl.prototype.handleMessage = function(event) {
  if (event.data == "playpause") { this.playPauseCallback(); }
  else if (event.data == "next") { this.nextCallback(); }
  else if (event.data == "prev") { this.prevCallback(); }
  else if (event.data == "heartbeat") { /* nop */ }
  else { console.log("Unknown websocket event"); console.log(event); }
}
