var TrackTable = function(colDescriptions, rowsPerPage, trackChanges) {
  this.table = $("#tracks");
  this.contextMenu = $("#context-menu");
  this.contextMenuPlay = this.contextMenu.find(".play");
  this.contextMenuPlayNext = this.contextMenu.find(".play-next");
  this.contextMenuDownload = this.contextMenu.find(".download");
  this.contextMenuInfo = this.contextMenu.find(".track-info");
  if (!trackChanges) { this.contextMenuInfo.hide(); }
  this.colDescriptions = colDescriptions;
  this.trackChanges = trackChanges;
  this.headerCells = [];
  this.rows = []
  this.cellMatrix = []; // multi-dimensional array - [rowsPerPage][cols.length]
  this.sortCol = -1;
  this.sortAsc = true;
  this.selectedRow = this.nowPlayingRow = -1;

  this.table.append("<thead><tr></tr></thead>");
  var tr = this.table.find("thead tr");

  for (var idx in colDescriptions) {
    var col = colDescriptions[idx];

    tr.append("<th class=\"sort-both\">" + col.name + "</th>");
    var th = tr.find("th:last");
    this.headerCells.push(th);
    th.click(function() { this.table.headerClicked(this.idx); }.bind({ table: this, idx: idx }));
  }

  this.table.append("<tbody></tbody>");
  var tbody = this.table.find("tbody");
  for (var i = 0; i < rowsPerPage; ++i) {
    var cols = []

    tbody.append("<tr></tr>");
    var tr = tbody.find("tr:last");
    tr.addClass(i % 2 == 1 ? "even" : "odd"); // 0th row is really 1st row, so odd
    this.rows.push(tr);

    for (var j = 0; j < this.colDescriptions.length; ++j) {
      var initializer = this.colDescriptions[j]["initializer"];
      tr.append("<td></td>");
      if (initializer) { initializer(tr.find("td:last-child")); }
      if (this.colDescriptions[j]["type"] == "numeric") { tr.find("td:last").addClass("align-right"); }
      cols.push(tr.find("td:last"));
    }

    this.cellMatrix.push(cols);

    tr.on("click", this.rowClicked.bind({ table: this, idx: i }));
    tr.on("dblclick", this.rowDoubleClicked.bind({ table: this, idx: i }));
    tr.on("contextmenu", this.rowRightClicked.bind({ table: this, idx: i }));
  }
}

TrackTable.prototype.setCallbacks = function(sortChangedCallback, clickCallback, playCallback, playNextCallback, downloadCallback, infoCallback) {
  this.sortChangedCallback = sortChangedCallback;
  this.clickCallback = clickCallback;
  this.playCallback = playCallback;
  this.playNextCallback = playNextCallback;
  this.downloadCallback = downloadCallback;
  this.infoCallback = infoCallback;
}

TrackTable.prototype.tracksChanged = function(tracks, selectedIndex, nowPlayingIndex) {
  var maxRow = tracks.length;
  if (tracks.length >= this.cellMatrix.length) { maxRow = this.cellMatrix.length; }

  for (var rowIdx = 0; rowIdx < maxRow; ++rowIdx) {
    console.assert(this.colDescriptions.length == this.cellMatrix[rowIdx].length);
    for (var colIdx in this.colDescriptions) {
      var formatter = this.colDescriptions[colIdx]["formatter"];
      if (formatter) {
        formatter(this.cellMatrix[rowIdx][colIdx], tracks[rowIdx][this.colDescriptions[colIdx]["data"]]);
      } else {
        this.cellMatrix[rowIdx][colIdx].text(tracks[rowIdx][this.colDescriptions[colIdx]["data"]]);
      }
    }
    this.rows[rowIdx].attr('data-track-id', tracks[rowIdx]['id']);
    this.rows[rowIdx].show();
  }

  // if there aren't enough rows, hide the remaining
  for (; rowIdx < this.cellMatrix.length; ++rowIdx) {
    this.rows[rowIdx].removeAttr('data-track-id');
    this.rows[rowIdx].hide();
  }

  this.updateSelectedRow(selectedIndex);
  this.updateNowPlayingRow(nowPlayingIndex);
}

TrackTable.prototype.updateSelectedRow = function(rowIdx) {
  if (this.selectedRow == rowIdx) { return; }

  if (this.selectedRow != -1) {
    this.rows[this.selectedRow].removeClass("selected");
  }

  this.selectedRow = rowIdx;

  if (this.selectedRow != -1) {
    this.rows[this.selectedRow].addClass("selected");
  }
}

TrackTable.prototype.updateNowPlayingRow = function(rowIdx) {
  if (this.nowPlayingRow != -1) {
    this.rows[this.nowPlayingRow].find("td:first-child i").remove();
    this.rows[this.nowPlayingRow].removeClass("now-playing");
  }

  this.nowPlayingRow = rowIdx;

  if (this.nowPlayingRow != -1) {
    this.rows[this.nowPlayingRow].addClass("now-playing");
    this.rows[this.nowPlayingRow].find("td:first-child").prepend('<i class="icon ion-ios-volume-high"></i>');
  }
}

TrackTable.prototype.headerClicked = function(colIdx) {
  if (this.sortCol != colIdx)
  {
    if (this.sortCol != -1) {
      this.clearSortingClasses(this.sortCol);
      this.headerCells[this.sortCol].addClass("sort-both");
    }

    this.sortCol = colIdx;
    this.sortAsc = false; // default to false since we negate below
  }

  this.sortAsc = !this.sortAsc;
  this.clearSortingClasses(this.sortCol);

  this.headerCells[this.sortCol].addClass(this.sortAsc ? "sort-asc" : "sort-desc");
  this.sortChangedCallback(this.sortCol, this.sortAsc);
}

TrackTable.prototype.clearSortingClasses = function(colIdx) {
  this.headerCells[this.sortCol].removeClass("sort-both");
  this.headerCells[this.sortCol].removeClass("sort-asc");
  this.headerCells[this.sortCol].removeClass("sort-desc");
}

TrackTable.prototype.rowClicked = function() {
  this.table.updateSelectedRow(this.idx);
  this.table.clickCallback(this.idx);
}

TrackTable.prototype.rowDoubleClicked = function() {
  this.table.playCallback(this.idx);
}

// https://stackoverflow.com/questions/18666601/use-bootstrap-3-dropdown-menu-as-context-menu
TrackTable.prototype.getMenuPosition = function(mousePosition, dimension, scrollDirection) {
  var windowSize = $(window)[dimension]();
  var menuSize = $("#context-menu")[dimension]();
  var position = mousePosition + $(window)[scrollDirection]();

  // opening menu would pass the side of the page
  if (mousePosition + menuSize > windowSize && menuSize < mousePosition) { position -= menuSize; }
  return position;
}

TrackTable.prototype.rowRightClicked = function(e) {
  this.table.updateSelectedRow(this.idx);
  this.table.clickCallback(this.idx);

  this.table.contextMenu.show().css({
    position: "absolute",
    left: this.table.getMenuPosition(e.clientX, "width", "scrollLeft"),
    top: this.table.getMenuPosition(e.clientY, "height", "scrollTop")
  })

  // the mousedown events stack, so we have to remove the old ones before re-adding them
  this.table.contextMenuPlay.off("mousedown");
  this.table.contextMenuPlayNext.off("mousedown");
  this.table.contextMenuDownload.off("mousedown");
  this.table.contextMenuInfo.off("mousedown");

  this.table.contextMenuPlay.mousedown(function() { this.table.playCallback(this.idx); }.bind(this));
  this.table.contextMenuPlayNext.mousedown(function() { this.table.playNextCallback(this.idx); }.bind(this));
  this.table.contextMenuDownload.mousedown(function() { this.table.downloadCallback(this.idx); }.bind(this));
  this.table.contextMenuInfo.mousedown(function() { console.assert(this.table.trackChanges); this.table.infoCallback(this.idx); }.bind(this));

  $("body").one("click", this.table.hideMenu.bind(this.table));
  $(document).one("mousedown", this.table.hideMenu.bind(this.table));

  return false;
}

TrackTable.prototype.hideMenu = function() {
  this.contextMenu.hide();
  this.contextMenuPlay.off("mousedown");
  this.contextMenuDownload.off("mousedown");
}
