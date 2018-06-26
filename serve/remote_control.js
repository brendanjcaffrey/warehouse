var RemoteControl = function(id, settings) {
  this.id = id;
  this.settings = settings;
  this.connected = false;
  this.websocket = null;

  this.div = $("<div class=\"input-group input-group-sm\"></div>").appendTo(id);

  this.address = $("<input type=\"text\" id=\"address\" class=\"form-control\" placeholder=\"localhost:9292\" />").appendTo(this.div);
  this.address.val(this.settings.getRemoteAddress());
  this.address.on('input', this.saveAddressValue.bind(this));

  span = $("<span class=\"input-group-btn\"></span>").appendTo(this.div);
  this.button = $("<input type=\"button\" value=\"Connect\" class=\"btn btn-success\" />").appendTo(span);
  this.button.click(this.connectButtonClick.bind(this));

  this.success = $("<span class=\"icon ion-checkmark form-control-feedback\" style=\"right: 77px; top: 4px;\"></span>").appendTo(id);
  this.failure = $("<span class=\"icon ion-close form-control-feedback\" style=\"right: 61px; top: 2px;\"></span>").appendTo(id);
  this.success.hide(); this.failure.hide();

  if (this.settings.getRemoteAddress() != "") { this.button.click(); }
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
