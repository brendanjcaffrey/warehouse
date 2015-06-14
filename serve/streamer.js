function to_hash(hash, object, index, array) {
  hash[object.id] = object;
  return hash;
}

// from http://stackoverflow.com/questions/6274339/how-can-i-shuffle-an-array-in-javascript
function shuffle(o) {
  for (var j, x, i = o.length; i; j = Math.floor(Math.random() * i), x = o[--i], o[i] = o[j], o[j] = x);
  return o;
}

var Streamer = function(data) {
  var artists = data["artists"].map(function (row) { return new Artist(row); }).reduce(to_hash, {});
  var albums = data["albums"].map(function (row) { return new Album(row); }).reduce(to_hash, {});
  var genres = data["genres"].map(function (row) { return new Genre(row); }).reduce(to_hash, {});
  this.tracks_arr = data["tracks"].map(function (row) { return new Track(row, artists, albums, genres); });
  this.tracks_hash = this.tracks_arr.reduce(to_hash, {});

  this.audio = document.getElementById("audio");

  this.playing = false;
  this.shuffle = false;
  this.repeat = false;

  this.playlist = [];
  this.playlistIndex = 0;

  this.nowPlayingRow = null;
  this.srcTrack = null;
}

Streamer.prototype.buildPlaylist = function(api) {
  if (api) streamer.api = api;

  streamer.playlist = streamer.api.rows({search: "applied"}).data().map(function (x) { return x.id });
  if (streamer.srcTrack) {
    // if the current song isn't in the results, then this will return -1,
    // which means the next song to be played will be index 0 which is what we want
    streamer.playlistIndex = streamer.playlist.indexOf(streamer.srcTrack.id);
  } else {
    streamer.playlistIndex = 0;
  }

  if (streamer.shuffle) {
    // pull out the currently playing track
    if (streamer.playlistIndex > 0) { streamer.playlist.splice(streamer.playlistIndex, 1); }
    streamer.playlist = shuffle(streamer.playlist);

    // and add it back at the beginning
    if (streamer.playlistIndex > 0) { streamer.playlist.unshift(streamer.srcTrack.id); }
    streamer.playlistIndex = 0;
  }
}

Streamer.prototype.setSrc = function(row) {
  streamer.clearSrc();

  $(row).addClass("now-playing");
  $(row).find("td:first-child").prepend('<i class="icon ion-ios-volume-high"></i>');

  var track = streamer.api.row(row).data();
  streamer.nowPlayingRow = row;
  streamer.srcTrack = track;

  // setting #t=123 at the end of the URL sets the start time cross browser
  $(streamer.audio).attr("src", "/tracks/" + String(track.id) + "." + track.ext + "#t=" + String(track.start));
  $(streamer.audio).attr("type", ext_to_type(track.ext));
}

Streamer.prototype.clearSrc = function() {
  if (streamer.nowPlayingRow) {
    $(streamer.nowPlayingRow).find("td i").remove();
    $(streamer.nowPlayingRow).removeClass("now-playing");
    streamer.nowPlayingRow = null;
    streamer.srcTrack = null;
  }

  $(streamer.audio).attr("src", "");
  $(streamer.audio).attr("type", "");
}

Streamer.prototype.play = function() {
  if (!streamer.nowPlayingRow) {
    var trackId = streamer.playlist[streamer.playlistIndex];
    streamer.api.rows(function(index, data, node) {
      if (data.id == trackId) streamer.setSrc(node);
    });
  }

  streamer.api.row(streamer.nowPlayingRow).show().draw(false);
  streamer.playing = true;
  $("#playpause").removeClass("ion-ios-play").addClass("ion-ios-pause");
  streamer.audio.play();
}

Streamer.prototype.stop = function() {
  streamer.audio.pause();
  streamer.clearSrc();
}

Streamer.prototype.pause = function() {
  streamer.playing = false;
  $("#playpause").removeClass("ion-ios-pause").addClass("ion-ios-play");
  streamer.audio.pause();
}

Streamer.prototype.prev = function() {
  if (streamer.repeat && streamer.srcTrack) {
    streamer.rewind();
    return;
  }

  streamer.playlistIndex--;
  if (streamer.playlistIndex < 0) {
    streamer.playlistIndex = streamer.playlist.length - 1;
  }

  if (streamer.nowPlayingRow) {
    streamer.stop(); streamer.play();
  }
}

Streamer.prototype.next = function() {
  if (streamer.repeat && streamer.srcTrack) {
    streamer.rewind();
    return;
  }

  streamer.playlistIndex++;
  if (streamer.playlistIndex >= streamer.playlist.length) {
    streamer.playlistIndex = 0;
  }

  if (streamer.nowPlayingRow) {
    streamer.stop(); streamer.play();
  }
}

Streamer.prototype.playPause = function() {
  if (streamer.playing) { streamer.pause(); }
  else                  { streamer.play(); }
}

Streamer.prototype.rewind = function() {
  streamer.audio.currentTime = streamer.srcTrack.start;
}

Streamer.prototype.toggleShuffle = function() {
  if (streamer.shuffle) {
    streamer.shuffle = false;
    $("#shuffle").addClass("disabled");
  } else {
    streamer.shuffle = true;
    $("#shuffle").removeClass("disabled");
  }

  streamer.buildPlaylist(null);
}

Streamer.prototype.toggleRepeat = function() {
  if (streamer.repeat) {
    streamer.repeat = false;
    $("#repeat").addClass("disabled");
  } else {
    streamer.repeat = true;
    $("#repeat").removeClass("disabled");
  }
}

Streamer.prototype.start = function() {
  $("#control, #tracks").removeClass("hidden");
  $("#loading").remove();

  $("#playpause").click(streamer.playPause);
  $("#prev").click(streamer.prev);
  $("#next").click(streamer.next);
  $("#shuffle").click(streamer.toggleShuffle);
  $("#repeat").click(streamer.toggleRepeat);

  var table = $("#tracks").DataTable({
    "drawCallback": function (settings) {
      streamer.buildPlaylist(this.api());
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
    "data": streamer.tracks_arr
  });

  table.page.len(100);
  table.draw();

  $("#tracks tbody").on("dblclick", "tr", function() {
    $(this).addClass("selected");
    streamer.setSrc(this);
    streamer.play();
    streamer.buildPlaylist(null);
  })

  $("#tracks tbody").on("click", "tr", function () {
    if ($(this).hasClass("selected")) {
      $(this).removeClass("selected");
    } else {
      table.$("tr.selected").removeClass("selected");
      $(this).addClass("selected");
    }
  });

  streamer.audio.addEventListener("timeupdate", function() {
    if (streamer.audio.currentTime >= streamer.audio.duration ||
        streamer.audio.currentTime >= streamer.srcTrack.finish) {
      streamer.next();
    }
  });
}

// the chrome extension will signal to us via this
window.addEventListener("message", function(event) {
  if (event.data.source != "itunes-streamer") return;

  switch (event.data.type) {
    case "play-pause": streamer.playPause(); break;
    case "next":       streamer.next(); break;
    case "prev":       streamer.prev(); break;
  }
}, false);

var streamer;
$(window).load(function() {
  $.getJSON("/data.json", function(data) {
    streamer = new Streamer(data);
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
  });
});
