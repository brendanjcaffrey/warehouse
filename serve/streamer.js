var Streamer = function(data) {
  var toHash = function(hash, object, index, array) {
    hash[object.id] = object;
    return hash;
  }

  var artists = data["artists"].map(function (row) { return new Artist(row); }).reduce(toHash, {});
  var albums = data["albums"].map(function (row) { return new Album(row); }).reduce(toHash, {});
  var genres = data["genres"].map(function (row) { return new Genre(row); }).reduce(toHash, {});

  this.tracksArr = data["tracks"].map(function (row) { return new Track(row, artists, albums, genres); });
  this.tracksHash = this.tracksArr.reduce(toHash, {});

  this.audio = new Audio(this);
  this.playlist = new Playlist(this.audio, this.tracksHash);

  this.stopped = true;
  this.playing = false;
  this.shuffle = false;
  this.repeat = false;

  this.skipRebuild = false;
  this.nowPlayingRow = null;
}

Streamer.prototype.highlightRow = function(row) {
  if (!$(row).hasClass("selected")) {
    $("tr.selected").removeClass("selected");
    $(row).addClass("selected");
  }
}

Streamer.prototype.manualRowPlay = function(row) {
  $(row).addClass("selected");
  this.setNowPlaying(row);
  this.playlist.rebuild(this.shuffle, this.stopped, this.api.row(row).data().id);
  this.play();
}

Streamer.prototype.hideMenu = function() {
  $('#contextMenu').remove();
}

Streamer.prototype.showMenu = function(row, e) {
  this.highlightRow(row);
  var menu = $('<ul id="contextMenu">');
  var self = this;

  var download = $('<li>Download</li>')
      .hover(function() { $(this).addClass("hover"); },
             function() { $(this).removeClass("hover"); })
      .mousedown(function() {
        var track = self.api.row(row).data();
        window.location = '/download/' + String(track.id) + '.' + String(track.ext);
      });
  menu.append(download);

  var play = $('<li>Play</li>')
      .hover(function() { $(this).addClass("hover"); },
             function() { $(this).removeClass("hover"); })
      .mousedown(function() { self.manualRowPlay(row); });
  menu.append(play);

  var x = e.pageX - 2;
  var y = e.pageY - 17;
  menu.css({ "position": "absolute", top: y, left: x });

  $("body").append(menu);
  $("body").one("click", this.hideMenu);
  $(document).one("mousedown", this.hideMenu);
}

Streamer.prototype.setNowPlaying = function(row) {
  this.clearNowPlaying();

  $(row).addClass("now-playing");
  $(row).find("td:first-child").prepend('<i class="icon ion-ios-volume-high"></i>');
  this.nowPlayingRow = row;
}

Streamer.prototype.clearNowPlaying = function() {
  if (this.nowPlayingRow) {
    $(this.nowPlayingRow).find("td i").remove();
    $(this.nowPlayingRow).removeClass("now-playing");
    this.nowPlayingRow = null;
  }

  this.audio.pause();
}

Streamer.prototype.play = function() {
  var self = this;

  var trackId = this.playlist.getCurrentTrackId();
  this.api.rows(function(index, data, node) {
    if (data.id == trackId) { self.setNowPlaying(node); }
  });

  if ($("input[type=search]").text() == "") {
    this.skipRebuild = true;
    this.api.row(this.nowPlayingRow).show().draw(false);
    this.skipRebuild = false;
  }

  this.stopped = false;
  this.playing = true;
  $("#playpause").removeClass("ion-ios-play").addClass("ion-ios-pause");
  this.audio.play();
}

Streamer.prototype.stop = function() {
  this.audio.pause();
  this.clearNowPlaying();
}

Streamer.prototype.pause = function() {
  this.playing = false;
  $("#playpause").removeClass("ion-ios-pause").addClass("ion-ios-play");
  this.audio.pause();
}

Streamer.prototype.prev = function() {
  if (this.repeat && this.audio.tryRewind()) { return; }

  this.playlist.moveBack();
  if (this.nowPlayingRow) { this.stop(); this.play(); }
}

Streamer.prototype.next = function() {
  if (this.repeat && this.audio.tryRewind()) { return; }

  this.playlist.moveForward();
  if (this.nowPlayingRow) { this.stop(); this.play(); }
}

Streamer.prototype.playPause = function() {
  if (this.playing) { this.pause(); }
  else              { this.play(); }
}

Streamer.prototype.toggleShuffle = function() {
  if (this.shuffle) {
    this.shuffle = false;
    $("#shuffle").addClass("disabled");
  } else {
    this.shuffle = true;
    $("#shuffle").removeClass("disabled");
  }

  this.playlist.rebuild(this.shuffle, this.stopped, this.audio.getNowPlayingTrackId());
}

Streamer.prototype.toggleRepeat = function() {
  if (this.repeat) {
    this.repeat = false;
    $("#repeat").addClass("disabled");
  } else {
    this.repeat = true;
    $("#repeat").removeClass("disabled");
  }
}

Streamer.prototype.start = function() {
  var self = this;

  $("#control-row, #content-row").removeClass("hidden");
  $("#loading").remove();

  $("#playpause").click(function() { self.playPause() });
  $("#prev").click(function() { self.prev() });
  $("#next").click(function() { self.next() });
  $("#shuffle").click(function() { self.toggleShuffle() });
  $("#repeat").click(function() { self.toggleRepeat() });

  $("#playpause, #prev, #next").mousedown(function() { $(this).addClass('disabled'); });
  $("#playpause, #prev, #next").mouseup(function() { $(this).removeClass('disabled'); });
  $("#playpause, #prev, #next").mouseleave(function() { $(this).removeClass('disabled'); });

  var table = $("#tracks").DataTable({
    "drawCallback": function (settings) {
      // when a track starts playing, we redraw the table to show its page
      // this is to prevent rebuilding the playlist when that happens
      if (self.skipRebuild) { return; }

      // this drawCallback is called immediately after defining the table,
      // so there's no way to gracefully set the api variable except here
      self.api = this.api();
      self.playlist.rebuild(self.shuffle, self.stopped, self.audio.getNowPlayingTrackId(), self.api);
    },
    "lengthChange": false,
    "columns": [
      { "data": { "_": "name", "sort": "sortName" } },
      { "data": { "_": "time", "sort": "duration" }, "type": "numeric" },
      { "data": { "_": "artist", "sort": "sortArtist" } },
      { "data": { "_": "album", "sort": "sortAlbum" } },
      { "data": "genre" },
      { "data": "playCount" },
    ],
    "data": self.tracksArr
  });

  table.page.len(50);
  table.draw();

  $("#tracks tbody").on("dblclick", "tr", function() { self.manualRowPlay(this); })
  $("#tracks tbody").on("click", "tr", function () { self.highlightRow(this); });
  $("#tracks tbody").on("contextmenu", "tr", function (e) {
    self.showMenu(this, e); return false;
  });
}

$(window).load(function() {
  $.getJSON("/data.json", function(data) {
    var streamer = new Streamer(data);
    streamer.start();
    $("#tracks_filter").detach().appendTo($("#filter"));

    $(document).bind("keydown", "right", function(e) {
      streamer.next(); return false;
    });

    $(document).bind("keydown", "left", function(e) {
      streamer.prev(); return false;
    });

    $(document).bind("keydown", "space", function(e) {
      streamer.playPause(); return false;
    });

    // this is how the chrome extension communicates with the web app
    window.addEventListener("message", function(event) {
      if (event.data.source != "itunes-streamer") { return; }

      switch (event.data.type) {
        case "play-pause": streamer.playPause(); break;
        case "next":       streamer.next(); break;
        case "prev":       streamer.prev(); break;
      }
    }, false);
  });
});
