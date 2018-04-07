var Pagination = function(id) {
  this.pagination = $(id);
  this.page = 0; // 0 is invalid value, valid range is 1-pages

  this.prevButton = $("<a>&lt;</a>").appendTo(this.pagination);
  this.firstButton = $("<a></a>").appendTo(this.pagination);
  this.firstEllipsis = $("<span class=\"ellipsis\">...</a>").appendTo(this.pagination);
  this.middleButtons = [
    $("<a></a>").appendTo(this.pagination),
    $("<a></a>").appendTo(this.pagination),
    $("<a></a>").appendTo(this.pagination)
  ];
  this.lastEllipsis = $("<span class=\"ellipsis\">...</a>").appendTo(this.pagination);
  this.lastButton = $("<a></a>").appendTo(this.pagination);
  this.nextButton = $("<a>&gt;</a>").appendTo(this.pagination);

  this.prevButton.click(this.prevButtonClicked.bind(this));
  this.firstButton.click(this.pageButtonClicked.bind({ pagination: this, button: this.firstButton }));
  for (var idx in this.middleButtons) {
    this.middleButtons[idx].click(this.pageButtonClicked.bind({ pagination: this, button: this.middleButtons[idx] }));
  }
  this.lastButton.click(this.pageButtonClicked.bind({ pagination: this, button: this.lastButton }));
  this.nextButton.click(this.nextButtonClicked.bind(this));
}

Pagination.prototype.setCallbacks = function(pageChangedCallback) {
  this.pageChangedCallback = pageChangedCallback;
}

Pagination.prototype.numPagesChanged = function(pages) {
  this.page = 1;
  this.pages = pages;
  this.updateDisplay();
}

Pagination.prototype.changedToPage = function(page) {
  this.showPage(page+1);
}

Pagination.prototype.pageChanged = function(page) {
  this.showPage(page);
  this.pageChangedCallback(page-1); // callback with page idx, not internal value
}

Pagination.prototype.showPage = function(page) {
  console.assert(page <= this.pages);

  this.page = page;
  this.updateDisplay();
}

Pagination.prototype.prevButtonClicked = function() {
  if (this.prevButton.hasClass("disabled")) { return false; }
  this.pageChanged(this.page-1);
}

Pagination.prototype.nextButtonClicked = function() {
  if (this.nextButton.hasClass("disabled")) { return false; }
  this.pageChanged(this.page+1);
}

Pagination.prototype.pageButtonClicked = function() {
  this.pagination.pageChanged(parseInt(this.button.text()));
}

Pagination.prototype.updateDisplay = function() {
  if (this.pages == 0)
  {
    this.pagination.hide();
    return;
  }

  this.pagination.show();
  this.firstButton.text('1');
  this.lastButton.text(this.pages);

  // disable previous button if we're on the first page
  if (this.page == 1) { this.prevButton.addClass("disabled"); this.firstButton.addClass("selected"); }
  else { this.prevButton.removeClass("disabled"); this.firstButton.removeClass("selected"); }

  // disable next button if we're on the last page
  if (this.page == this.pages) { this.nextButton.addClass("disabled"); this.lastButton.addClass("selected");}
  else { this.nextButton.removeClass("disabled"); this.lastButton.removeClass("selected"); }

  // only show the first ellipsis if there's more pages than buttons and we're far enough that there's a gap between 1 and the first middle button
  var showFirstEllipsis = (this.pages > 5 && this.page > 3);
  showFirstEllipsis ? this.firstEllipsis.show() : this.firstEllipsis.hide();

  // only show the last ellipsis if there's more pages than buttons and we're far enough from the end that there's a gap between the last middle button and the last
  var showLastEllipsis = (this.pages > 5 && this.page <= this.pages-3);
  showLastEllipsis ? this.lastEllipsis.show() : this.lastEllipsis.hide();

  // how many buttons do we need
  this.pages <= 1 ? this.lastButton.hide() : this.lastButton.show();
  this.pages <= 2 ? this.middleButtons[0].hide() : this.middleButtons[0].show();
  this.pages <= 3 ? this.middleButtons[1].hide() : this.middleButtons[1].show();
  this.pages <= 4 ? this.middleButtons[2].hide() : this.middleButtons[2].show();

  for (var idx in this.middleButtons) { this.middleButtons[idx].removeClass("selected"); }
  if (!showFirstEllipsis)
  {
    this.middleButtons[0].text('2');
    this.middleButtons[1].text('3');
    this.middleButtons[2].text('4');
    if (this.page > 1 && this.page < 5) { this.middleButtons[this.page-2].addClass("selected"); }
  }
  else if (!showLastEllipsis)
  {
    this.middleButtons[0].text(this.pages - 3);
    this.middleButtons[1].text(this.pages - 2);
    this.middleButtons[2].text(this.pages - 1);
    if (this.page == this.pages-2) { this.middleButtons[1].addClass("selected"); }
    if (this.page == this.pages-1) { this.middleButtons[2].addClass("selected"); }
  }
  else
  {
    this.middleButtons[0].text(this.page - 1);
    this.middleButtons[1].text(this.page);
    this.middleButtons[2].text(this.page + 1);
    this.middleButtons[1].addClass("selected");
  }

  // if <= 5:
  //   1 -> prev (disabled) [1] 2 3 4 5 next
  //   2 -> prev 1 [2] 3 4 5 next
  //   3 -> prev 1 2 [3] 4 5 next
  //   4 -> prev 1 2 3 [4] 5 next
  //   5 -> prev 1 2 3 4 [5] next (disabled)
  // else:
  //   1 -> prev (disabled) [1] 2 3 4 ... 9 next (unless max is <= 5?)
  //   2 -> prev 1 [2] 3 4 ... 9 next (unless max is <= 5?)
  //   3 -> prev 1 2 [3] 4 ... 9 next (unless max is <= 5?)
  //   4 -> prev 1 ... 3 [4] 5 ... 9 next (unless max is <= 5?)
  //   ...
  //   6 -> prev 1 ... 5 [6] 7 ... 9 next
  //   7 -> prev 1 ... 6 [7] 8 9 next
  //   8 -> prev 1 ... 6 7 [8] 9 next
  //   9 -> prev 1 ... 6 7 8 [9] next (disabled)
}
