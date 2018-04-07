var TrackTable = function(tableId, colDescriptions, rowsPerPage) {
  this.table = $(tableId);
  this.colDescriptions = colDescriptions;
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
      tr.append("<td></td>");
      if (this.colDescriptions[j]["type"] == "numeric") { tr.find("td:last").addClass("align-right"); }
      cols.push(tr.find("td:last"));
    }

    this.cellMatrix.push(cols);

    tr.on("click", this.rowClicked.bind({ table: this, idx: i }));
    tr.on("dblclick", this.rowDoubleClicked.bind({ table: this, idx: i }));
    tr.on("contextmenu", this.rowRightClicked.bind({ table: this, idx: i }));
  }
}

TrackTable.prototype.setCallbacks = function(sortChangedCallback, clickCallback, playCallback, downloadCallback) {
  this.sortChangedCallback = sortChangedCallback;
  this.clickCallback = clickCallback;
  this.playCallback = playCallback;
  this.downloadCallback = downloadCallback;
}

TrackTable.prototype.tracksChanged = function(tracks, selectedIndex, nowPlayingIndex) {
  var maxRow = tracks.length;
  if (tracks.length >= this.cellMatrix.length) { maxRow = this.cellMatrix.length; }

  for (var rowIdx = 0; rowIdx < maxRow; ++rowIdx) {
    console.assert(this.colDescriptions.length == this.cellMatrix[rowIdx].length);
    for (var colIdx in this.colDescriptions) {
      this.cellMatrix[rowIdx][colIdx].text(tracks[rowIdx][this.colDescriptions[colIdx]["data"]]);
    }
    this.rows[rowIdx].show();
  }

  // if there aren't enough rows, hide the remaining
  for (; rowIdx < this.cellMatrix.length; ++rowIdx) {
    for (var colIdx in this.colDescriptions) {
      this.cellMatrix[rowIdx][colIdx].text("");
    }
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
    this.rows[this.nowPlayingRow].find("td i").remove();
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

TrackTable.prototype.rowRightClicked = function(e) {
  this.table.updateSelectedRow(this.idx);
  this.table.clickCallback(this.idx);

  var menu = $('<ul id="context-menu">');

  var download = $("<li>Download</li>")
      .hover(function() { $(this).addClass("hover"); },
             function() { $(this).removeClass("hover"); })
      .mousedown(function() { this.table.downloadCallback(this.idx); }.bind(this));
  menu.append(download);

  var play = $("<li>Play</li>")
      .hover(function() { $(this).addClass("hover"); },
             function() { $(this).removeClass("hover"); })
      .mousedown(function() { this.table.playCallback(this.idx); }.bind(this));
  menu.append(play);

  var x = e.pageX - 2;
  var y = e.pageY - 17;
  menu.css({ "position": "absolute", "top": y, "left": x });

  $("body").append(menu);
  $("body").one("click", this.table.hideMenu);
  $(document).one("mousedown", this.table.hideMenu);

  return false;
}

TrackTable.prototype.hideMenu = function() {
  $("#context-menu").remove();
}
