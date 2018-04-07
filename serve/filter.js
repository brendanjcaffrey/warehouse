var Filter = function(tracksHash, colDescriptions) {
  this.tracksHash = tracksHash;
  this.filterableKeys = []
  for (var idx in colDescriptions) {
    var col = colDescriptions[idx];
    if (!('filter' in col) || col.filter) { this.filterableKeys.push(col.data); }
  }
}

Filter.prototype.setCallbacks = function(displayChangedCallback) {
  this.displayChangedCallback = displayChangedCallback;
}

Filter.prototype.filterCleared = function() {
  this.text = "";
}

Filter.prototype.filterChanged = function(text) {
  if (text != this.text) {
    this.text = text;
    this.displayChangedCallback();
  }
}

Filter.prototype.filterTrackList = function(unfilteredTrackIds) {
  if (this.text == "") { return unfilteredTrackIds; }

  var words = this.text.toLowerCase().split(" ").filter(word => word.length > 0);
  var filteredTrackIds = [];

  for (var trackIdx in unfilteredTrackIds) {
    var trackId = unfilteredTrackIds[trackIdx];
    var track = this.tracksHash[trackId];
    var allFound = true;

    for (var wordIdx in words) {
      var word = words[wordIdx];
      var wordFound = false;

      for (var keyIdx in this.filterableKeys) {
        var keyName = this.filterableKeys[keyIdx];
        if (track[keyName].toLowerCase().indexOf(word) != -1) {
          wordFound = true;
          break;
        }
      }

      if (!wordFound) {
        allFound = false;
        break;
      }
    }

    if (allFound) {
      filteredTrackIds.push(unfilteredTrackIds[trackIdx]);
    }
  }

  return filteredTrackIds;
}

