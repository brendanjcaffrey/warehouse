var Ratings = function(tracksHash, trackChanges) {
  this.tracksHash = tracksHash;
  this.trackChanges = trackChanges;
}

Ratings.prototype.clearClick = function(e) {
  e.stopPropagation()
  this.ratings.updateRating(this.cell, 0);
}

Ratings.prototype.starClick = function(e) {
  console.assert(this.ratings.trackChanges);
  e.stopPropagation()
  var target = $(e.currentTarget);
  var left = (e.pageX - target.offset().left) < (target.width() / 2.0);
  var newRating = this.offset + (left ? 10 : 20);
  this.ratings.updateRating(this.cell, newRating);
}

Ratings.prototype.updateRating = function(cell, newRating) {
  this.format(cell, newRating);

  var id = cell.closest("tr").attr("data-track-id")
  if (this.tracksHash[id]) {
    this.tracksHash[id].rating = newRating;
    $.post('/rating/' + id, { rating: newRating });
  }
};

Ratings.prototype.initialize = function(cell) {
  cell.html('<div id="rating-wrapper"><i/><i/><i/><i/><i/></div>');
  if (this.trackChanges) {
    cell.find("div").click(this.clearClick.bind({ ratings: this, cell: cell }));
    cell.find("i:nth-child(1)").click(this.starClick.bind({ ratings: this, cell: cell, offset: 0 }));
    cell.find("i:nth-child(2)").click(this.starClick.bind({ ratings: this, cell: cell, offset: 20 }));
    cell.find("i:nth-child(3)").click(this.starClick.bind({ ratings: this, cell: cell, offset: 40 }));
    cell.find("i:nth-child(4)").click(this.starClick.bind({ ratings: this, cell: cell, offset: 60 }));
    cell.find("i:nth-child(5)").click(this.starClick.bind({ ratings: this, cell: cell, offset: 80 }));
  }
};

Ratings.prototype.getClass = function(actualRating, halfAmount) {
  if (actualRating < halfAmount) { return "icon ion-ios-star-outline"; }
  else if (actualRating == halfAmount) { return "icon ion-ios-star-half"; }
  else { return "icon ion-ios-star"; }
};

Ratings.prototype.format = function(cell, rating) {
  cell.find("i:nth-child(1)").removeClass().addClass(this.getClass(rating, 10));
  cell.find("i:nth-child(2)").removeClass().addClass(this.getClass(rating, 30));
  cell.find("i:nth-child(3)").removeClass().addClass(this.getClass(rating, 50));
  cell.find("i:nth-child(4)").removeClass().addClass(this.getClass(rating, 70));
  cell.find("i:nth-child(5)").removeClass().addClass(this.getClass(rating, 90));
};
