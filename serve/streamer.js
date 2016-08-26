var PersistentSettings = function() {
  cookies = Cookies.get();
  // both default to false
  this.shuffle = (Cookies.get("shuffle") == "1");
  this.repeat  = (Cookies.get("repeat") == "1");
}

PersistentSettings.prototype.persist = function() {
  Cookies.set("shuffle", this.shuffle ? "1" : "0", { expires: 60 });
  Cookies.set("repeat", this.repeat ? "1" : "0", { expires: 60 });
}

PersistentSettings.prototype.getShuffle = function() { return this.shuffle; }
PersistentSettings.prototype.setShuffle = function(shuffle) {
  this.shuffle = shuffle;
  this.persist();
}

PersistentSettings.prototype.getRepeat = function() { return this.repeat; }
PersistentSettings.prototype.setRepeat = function(repeat) {
  this.repeat = repeat;
  this.persist();
}


var Streamer = function(data) {
  var toHash = function(hash, object, index, array) {
    hash[object.id] = object;
    return hash;
  }

  var artists = data["artists"].map(function (row) { return new Artist(row); }).reduce(toHash, {});
  var albums = data["albums"].map(function (row) { return new Album(row); }).reduce(toHash, {});
  var genres = data["genres"].map(function (row) { return new Genre(row); }).reduce(toHash, {});

  var sortStr = function(i1, i2) {
    if (i1.searchName == i2.searchName) { return 0; }
    else if (i1.searchName > i2.searchName) { return 1; }
    else { return -1; }
  }
  this.tracksArr = data["tracks"].map(function (row) { return new Track(row, artists, albums, genres); }).sort(sortStr);
  this.tracksHash = this.tracksArr.reduce(toHash, {});

  this.settings = new PersistentSettings();
  this.audio = new Audio(this);
  this.playlist = new Playlist(this.audio, this.settings, this.tracksHash);

  this.stopped = true;
  this.playing = false;

  this.skipRebuild = false;
  this.nowPlayingRow = this.selectedRow = null;

  this.letterPressString = "";
  this.letterPressTimeoutID = null;
}

Streamer.prototype.highlightRow = function(row) {
  if (!$(row).hasClass("selected")) {
    if (this.selectedRow) { $(this.selectedRow).removeClass("selected"); }
    $(row).addClass("selected");
  }

  this.selectedRow = row;
}

Streamer.prototype.manualRowPlay = function(row) {
  this.highlightRow(row);
  this.setNowPlaying(row);
  // we pass in false for stopped here to get the playlist to use the song we just set as playing
  this.playlist.rebuild(false, this.api.row(row).data().id);
  this.play();
}

Streamer.prototype.hideMenu = function() {
  $("#contextMenu").remove();
}

Streamer.prototype.showMenu = function(row, e) {
  this.highlightRow(row);
  var menu = $('<ul id="contextMenu">');
  var self = this;

  var download = $("<li>Download</li>")
      .hover(function() { $(this).addClass("hover"); },
             function() { $(this).removeClass("hover"); })
      .mousedown(function() {
        var track = self.api.row(row).data();
        window.location = "/download/" + String(track.id);
      });
  menu.append(download);

  var play = $("<li>Play</li>")
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

Streamer.prototype.findRowForTrackId = function(trackId) {
  var ret = null;
  this.api.rows(function(index, data, node) {
    if (data.id == trackId) { ret = node; }
  });

  return ret;
}

Streamer.prototype.showRow = function(row) {
  this.skipRebuild = true;
  this.api.row(row).show().draw(false);
  this.skipRebuild = false;
}

Streamer.prototype.play = function() {
  var row = this.findRowForTrackId(this.playlist.getCurrentTrackId());
  this.setNowPlaying(row);
  this.showRow(row);

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
  if (this.settings.getRepeat() && this.audio.tryRewind()) { return; }

  this.playlist.moveBack();
  if (this.nowPlayingRow) { this.stop(); this.play(); }
}

Streamer.prototype.next = function() {
  if (this.settings.getRepeat() && this.audio.tryRewind()) { return; }

  this.playlist.moveForward();
  if (this.nowPlayingRow) { this.stop(); this.play(); }
}

Streamer.prototype.playPause = function() {
  if (this.playing) { this.pause(); }
  else              { this.play(); }
}

Streamer.prototype.toggleShuffle = function() {
  if (this.settings.getShuffle()) {
    this.settings.setShuffle(false);
    $("#shuffle").addClass("disabled");
  } else {
    this.settings.setShuffle(true);
    $("#shuffle").removeClass("disabled");
  }

  this.playlist.rebuild(this.stopped, this.audio.getNowPlayingTrackId());
}

Streamer.prototype.toggleRepeat = function() {
  if (this.settings.getRepeat()) {
    this.settings.setRepeat(false);
    $("#repeat").addClass("disabled");
  } else {
    this.settings.setRepeat(true);
    $("#repeat").removeClass("disabled");
  }
}

Streamer.prototype.volumeUpdated = function(value) {
  this.audio.updateAllVolumes(value);
}

Streamer.prototype.volumeUp = function() {
  value = this.audio.currentVolume + 10;
  if (value > 100) { value = 100; }

  this.volumeUpdated(value);
  this.volume.slider("setValue", value);
}

Streamer.prototype.volumeDown = function() {
  value = this.audio.currentVolume - 10;
  if (value < 0) { value = 0; }

  this.volumeUpdated(value);
  this.volume.slider("setValue", value);
}

Streamer.prototype.onLetterPress = function(letter) {
  var self = this;
  self.letterPressString += letter;

  if (self.letterPressTimeoutID != null) {
    window.clearTimeout(self.letterPressTimeoutID);
    self.letterPressTimeoutID = null;
  }

  self.letterPressTimeoutID = window.setTimeout(function() {
    track = self.tracksArr.find(function(track) { return track.searchName.substr(0, self.letterPressString.length) >= self.letterPressString; });
    var row = self.findRowForTrackId(track.id);
    self.highlightRow(row);
    self.showRow(row);

    self.letterPressString = "";
    self.letterPressTimeoutID = null;
  }, 750);
}

Streamer.prototype.start = function() {
  var self = this;

  if (!self.settings.getShuffle()) { $("#shuffle").addClass("disabled"); }
  if (!self.settings.getRepeat()) { $("#repeat").addClass("disabled"); }

  $("#control-row, #content-row").removeClass("hidden");
  $("#loading").remove();

  $("#playpause").click(function() { self.playPause() });
  $("#prev").click(function() { self.prev() });
  $("#next").click(function() { self.next() });
  $("#shuffle").click(function() { self.toggleShuffle() });
  $("#repeat").click(function() { self.toggleRepeat() });

  $("#playpause, #prev, #next").mousedown(function() { $(this).addClass("disabled"); });
  $("#playpause, #prev, #next").mouseup(function() { $(this).removeClass("disabled"); });
  $("#playpause, #prev, #next").mouseleave(function() { $(this).removeClass("disabled"); });

  // create slider, initialize volume to 50%
  this.volume = $("#volume").slider({value: 50}).
    on("slide", function(slider) { self.volumeUpdated(slider.value); });
  self.volumeUpdated(50);

  var table = $("#tracks").DataTable({
    "drawCallback": function (settings) {
      // when a track starts playing, we redraw the table to show its page
      // this is to prevent rebuilding the playlist when that happens
      if (self.skipRebuild) { return; }

      // this drawCallback is called immediately after defining the table,
      // so there's no way to gracefully set the api variable except here
      self.api = this.api();
      self.playlist.rebuild(self.stopped, self.audio.getNowPlayingTrackId(), self.api);
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

var streamer;
$(window).load(function() {
  $.getJSON("/data.json", function(data) {
    streamer = new Streamer(data);
    streamer.start();
    $("#tracks_filter").detach().appendTo($("#filter"));

    $(document).bind("keydown", "right", function(e) {
      streamer.next(); return false;
    });

    $(document).bind("keydown", "left", function(e) {
      streamer.prev(); return false;
    });

    $(document).bind("keydown", "space", function(e) {
      if (streamer.letterPressTimeoutID != null) { streamer.onLetterPress(" "); }
      else { streamer.playPause(); }
      return false;
    });

    $(document).bind("keydown", "ctrl+up", function(e) {
      streamer.volumeUp(); return false;
    });

    $(document).bind("keydown", "ctrl+down", function(e) {
      streamer.volumeDown(); return false;
    });

    // this is how the chrome extension communicates with the web app
    window.addEventListener("message", function(event) {
      if (event.data.source != "itunes-streamer") { return; }

      switch (event.data.type) {
        case "play-pause":  streamer.playPause(); break;
        case "next":        streamer.next(); break;
        case "prev":        streamer.prev(); break;
        case "volume-up":   streamer.volumeUp(); break;
        case "volume-down": streamer.volumeDown(); break;
      }
    }, false);

    var alphabet = "abcdefghijklmnopqrstuvwxyz".split("");
    $.each(alphabet, function(i, e) {
      $(document).bind("keydown", alphabet[i], function(e) {
        streamer.onLetterPress(alphabet[i]);
      });
    });
  });
});
