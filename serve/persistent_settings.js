var PersistentSettings = function() {
  cookies = Cookies.get();
  // both default to false
  this.shuffle = (Cookies.get("shuffle") == "1");
  this.repeat  = (Cookies.get("repeat") == "1");

  var openFolders = Cookies.get("openFolders");
  if (openFolders) {
    this.openFolders = openFolders.split(",").map(function(id) { return parseInt(id) });
  } else {
    this.openFolders = [];
  }
}

PersistentSettings.prototype.persist = function() {
  Cookies.set("shuffle", this.shuffle ? "1" : "0", { expires: 60 });
  Cookies.set("repeat", this.repeat ? "1" : "0", { expires: 60 });
  Cookies.set("openFolders", this.openFolders.join(","), { expires: 60 });
}

PersistentSettings.prototype.getShuffle = function() { return this.shuffle; }
PersistentSettings.prototype.setShuffle = function(shuffle) {
  this.shuffle = shuffle;
  this.persist();
}

PersistentSettings.prototype.getRepeat = function() { return this.repeat; }
PersistentSettings.prototype.setRepeat = function(repeat) {
  this.repeat = repeat;
  this.persist();
}

PersistentSettings.prototype.getFolderOpen = function(folderId) { return this.openFolders.indexOf(folderId) != -1; }
PersistentSettings.prototype.setFolderOpen = function(folderId) {
  if (this.getFolderOpen(folderId)) { return; }
  this.openFolders.push(folderId);
  this.persist();
}
PersistentSettings.prototype.setFolderClosed = function(folderId) {
  var index = this.openFolders.indexOf(folderId);
  if (index == -1) { return; }
  this.openFolders.splice(index, 1);
  this.persist();
}
