var FilterBar = function(id) {
  $(id).append("<label>Search: <input type=\"search\" /></label>");
  this.input = $(id).find("input");
  // the "input" event fires every time the value changes, but the "change" event only fires when "committed"?
  this.input.on('input', this.textChanged.bind(this));
}

FilterBar.prototype.setCallbacks = function(filterChangedCallback, filterClearedCallback) {
  this.filterChangedCallback = filterChangedCallback;
  this.filterClearedCallback = filterClearedCallback;
}

FilterBar.prototype.textChanged = function() {
  this.filterChangedCallback(this.input.val());
}

FilterBar.prototype.clearFilter = function() {
  this.input.val("");
  this.filterClearedCallback();
}
