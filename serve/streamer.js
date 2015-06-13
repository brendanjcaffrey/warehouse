function to_hash(hash, object, index, array) {
  hash[object.id] = object;
  return hash;
}

var Streamer = function(data) {
  var artists = data["artists"].map(function (row) { return new Artist(row); }).reduce(to_hash, {});
  var albums = data["albums"].map(function (row) { return new Album(row); }).reduce(to_hash, {});
  var genres = data["genres"].map(function (row) { return new Genre(row); }).reduce(to_hash, {});

  this.tracks = data["tracks"].map(function (row) { return new Track(row, artists, albums, genres); });

  this.isPlaying = false;
  this.audio = document.getElementById("audio");
  this.nowPlayingRow;
}

Streamer.prototype.setSrc = function(row) {
  streamer.clearSrc();

  $(row).addClass('now-playing');
  $(row).find('td:first-child').prepend('<i class="icon ion-ios-volume-high"></i>');

  streamer.nowPlayingRow = row;
  var track = table.row(row).data();

  $(streamer.audio).attr('src', "/tracks/" + String(track.id) + "." + track.ext);
  $(streamer.audio).attr('type', ext_to_type(track.ext));
}

Streamer.prototype.clearSrc = function() {
  if (streamer.nowPlayingRow) {
    $(streamer.nowPlayingRow).find('td i').remove();
    $(streamer.nowPlayingRow).removeClass('now-playing');
    streamer.nowPlayingRow = null;
  }

  $(streamer.audio).attr('src', '');
  $(streamer.audio).attr('type', '');
}

Streamer.prototype.play = function() {
  if (!streamer.nowPlayingRow) return;

  streamer.isPlaying = true;
  $("#playpause").removeClass('ion-ios-play').addClass('ion-ios-pause');
  streamer.audio.play();
}

Streamer.prototype.pause = function() {
  streamer.isPlaying = false;
  $("#playpause").removeClass('ion-ios-pause').addClass('ion-ios-play');
  streamer.audio.pause();
}

Streamer.prototype.prev = function() {
}

Streamer.prototype.next = function() {
}

Streamer.prototype.playPause = function() {
  if (streamer.isPlaying) { streamer.pause(); }
  else                    { streamer.play(); }
}

Streamer.prototype.start = function() {
  $("#control, #tracks").removeClass("hidden");
  $("#loading").remove();

  $("#playpause").click(streamer.playPause);
  $("#prev").click(streamer.prev);
  $("#next").click(streamer.next);

  table = $("#tracks").DataTable({
    "lengthChange": false,
    "columns": [
      { "data": { "_": "name", "sort": "sort_name" } },
      { "data": { "_": "time", "sort": "duration" }, "type": "numeric" },
      { "data": { "_": "artist", "sort": "sort_artist" } },
      { "data": { "_": "album", "sort": "sort_album" } },
      { "data": "genre" },
      { "data": "play_count" },
    ],
    "data": streamer.tracks
  });

  table.page.len(100);
  table.draw();

  $("#tracks tbody").on('dblclick', 'tr', function() {
    $(this).addClass('selected');
    streamer.setSrc(this);
    streamer.play();
  })

  $('#tracks tbody').on('click', 'tr', function () {
    if ($(this).hasClass('selected')) {
      $(this).removeClass('selected');
    } else {
      table.$('tr.selected').removeClass('selected');
      $(this).addClass('selected');
    }
  });
}

var streamer, table;
$(window).load(function() {
  $.getJSON("/data.json", function(data) {
    streamer = new Streamer(data);
    streamer.start();
  });
});
