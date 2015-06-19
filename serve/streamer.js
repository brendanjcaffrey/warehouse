var Streamer = function(data) {
  var to_hash = function(hash, object, index, array) {
    hash[object.id] = object;
    return hash;
  }

  var artists = data["artists"].map(function (row) { return new Artist(row); }).reduce(to_hash, {});
  var albums = data["albums"].map(function (row) { return new Album(row); }).reduce(to_hash, {});
  var genres = data["genres"].map(function (row) { return new Genre(row); }).reduce(to_hash, {});

  this.tracks_arr = data["tracks"].map(function (row) { return new Track(row, artists, albums, genres); });
  this.tracks_hash = this.tracks_arr.reduce(to_hash, {});

  this.audio = new Audio(this);
  this.playlist = new Playlist();

  this.playing = false;
  this.shuffle = false;
  this.repeat = false;

  this.skipRebuild = false;
  this.nowPlayingRow = null;
}

Streamer.prototype.setNowPlaying = function(row) {
  this.clearNowPlaying();

  $(row).addClass("now-playing");
  $(row).find("td:first-child").prepend('<i class="icon ion-ios-volume-high"></i>');

  var track = this.api.row(row).data();
  this.nowPlayingRow = row;
  this.audio.load(track);
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

  if (!this.nowPlayingRow) {
    var trackId = this.playlist.getCurrentTrackId();
    this.api.rows(function(index, data, node) {
      if (data.id == trackId) self.setNowPlaying(node);
    });
  }

  this.skipRebuild = true;
  this.api.row(this.nowPlayingRow).show().draw(false);
  this.skipRebuild = false;

  var next = this.tracks_hash[this.playlist.getNextTrackId()];
  if (next.id != this.playlist.getCurrentTrackId()) this.audio.preload(next);

  this.playing = true;
  $("#playpause").removeClass("ion-ios-play").addClass("ion-ios-pause");
  this.audio.play();
  this.audio
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
  if (this.repeat && this.audio.tryRewind()) return;

  this.playlist.moveBack();
  if (this.nowPlayingRow) { this.stop(); this.play(); }
}

Streamer.prototype.next = function() {
  if (this.repeat && this.audio.tryRewind()) return;

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

  this.playlist.rebuild(this.shuffle, this.audio.getNowPlayingTrackId());
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

  $("#control, #tracks").removeClass("hidden");
  $("#loading").remove();

  $("#playpause").click(function() { self.playPause() });
  $("#prev").click(function() { self.prev() });
  $("#next").click(function() { self.next() });
  $("#shuffle").click(function() { self.toggleShuffle() });
  $("#repeat").click(function() { self.toggleRepeat() });

  var table = $("#tracks").DataTable({
    "drawCallback": function (settings) {
      // when a track starts playing, we redraw the table to show its page
      // this is to prevent rebuilding the playlist when that happens
      if (self.skipRebuild) return;

      // this drawCallback is called immediately after defining the table,
      // so there's no way to gracefully set this except here
      self.api = this.api();
      self.playlist.rebuild(self.shuffle, self.audio.getNowPlayingTrackId(), self.api);
    },
    "lengthChange": false,
    "columns": [
      { "data": { "_": "name", "sort": "sort_name" } },
      { "data": { "_": "time", "sort": "duration" }, "type": "numeric" },
      { "data": { "_": "artist", "sort": "sort_artist" } },
      { "data": { "_": "album", "sort": "sort_album" } },
      { "data": "genre" },
      { "data": "play_count" },
    ],
    "data": self.tracks_arr
  });

  table.page.len(50);
  table.draw();

  $("#tracks tbody").on("dblclick", "tr", function() {
    $(this).addClass("selected");
    self.setNowPlaying(this);
    self.playlist.rebuild(self.shuffle, self.audio.getNowPlayingTrackId());
    self.play();
  })

  $("#tracks tbody").on("click", "tr", function () {
    if (!$(this).hasClass("selected")) {
      table.$("tr.selected").removeClass("selected");
      $(this).addClass("selected");
    }
  });
}

$(window).load(function() {
  $.getJSON("/data.json", function(data) {
    var streamer = new Streamer(data);
    streamer.start();

    $(document).bind("keydown", "right", function(e) {
      streamer.next();
      return false;
    });

    $(document).bind("keydown", "left", function(e) {
      streamer.prev();
      return false;
    });

    $(document).bind("keydown", "space", function(e) {
      streamer.playPause();
      return false;
    });

    // this is how the chrome extension communicates with the web app
    window.addEventListener("message", function(event) {
      if (event.data.source != "itunes-streamer") return;

      switch (event.data.type) {
        case "play-pause": streamer.playPause(); break;
        case "next":       streamer.next(); break;
        case "prev":       streamer.prev(); break;
      }
    }, false);
  });
});
