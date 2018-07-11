var FilterBar = function() {
  var formGroup = $("<div class=\"form-group has-feedback has-feedback-left\"></div>").appendTo("#filter")
  this.input = $("<input type=\"search\" id=\"filter-bar\" class=\"form-control input-sm\" placeholder=\"Search\" />").appendTo(formGroup);
  $("<i class=\"form-control-feedback icon ion-ios-search\">").appendTo(formGroup);

  // the "input" event fires every time the value changes, but the "change" event only fires when "committed"
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
