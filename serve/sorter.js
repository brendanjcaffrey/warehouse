var Sorter = function(tracksHash, colDescriptions) {
  this.tracksHash = tracksHash;
  this.colDescriptions = [];
  for (var idx in colDescriptions) {
    var col = colDescriptions[idx];
    if (!('sort' in col)) { col.sort = [col.data]; }
    this.colDescriptions.push(col);
  }

  this.sortColIdx = -1;
  this.sortAsc = true;
}

Sorter.prototype.setCallbacks = function(displayChangedCallback) {
  this.displayChangedCallback = displayChangedCallback;
}

Sorter.prototype.sortChanged = function(colIdx, sortAsc) {
  this.sortColIdx = colIdx;
  this.sortAsc = sortAsc;
  this.displayChangedCallback();
}

Sorter.prototype.sortTrackList = function(trackIds) {
  if (this.sortColIdx != -1) {
    var sortVals = this.colDescriptions[this.sortColIdx].sort;
    trackIds.sort((l, r) => {
      var lTrack = this.tracksHash[l];
      var rTrack = this.tracksHash[r];
      for (var idx in sortVals) {
        var lVal = lTrack[sortVals[idx]];
        var rVal = rTrack[sortVals[idx]];
        if (typeof(lVal) == "string") {
          lVal = lVal.toLowerCase(); rVal = rVal.toLowerCase();
        }

        if (lVal == rVal) { continue; }
        return lVal > rVal ? 1 : -1;
      }
      return 0;
    });

    if (!this.sortAsc) { trackIds.reverse(); }
  }

  return trackIds;
}

Sorter.prototype.sortForTypeToShowList = function(trackIds) {
  var sortIdx = this.sortColIdx;
  if (this.sortColIdx == -1 || !this.colDescriptions[this.sortColIdx].typeToShow) {
    sortIdx = 0;
  }

  var sortVal = this.colDescriptions[sortIdx].sort;
  var typeToShowList = trackIds.map((trackId, index) => [this.tracksHash[trackId][sortVal].toLowerCase(), index]);
  typeToShowList.sort((l, r) => {
    if (l[0] == r[0]) { return 0; }
    else if (l[0] < r[0]) { return -1; }
    else { return 1; }
  });

  return typeToShowList;
}
