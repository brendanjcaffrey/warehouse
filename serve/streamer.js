var Streamer = function(data) {
  var toHash = function(hash, object, idx, array) {
    hash[object.id] = object;
    return hash;
  }

  // models
  var artists = data["artists"].map(row => new Artist(row)).reduce(toHash, {});
  var albums = data["albums"].map(row => new Album(row)).reduce(toHash, {});
  var genres = data["genres"].map(row => new Genre(row)).reduce(toHash, {});
  var playlists = data["playlists"].map(row => new Playlist(row));
  var playlistTracks = data["playlist_tracks"].map(row => new PlaylistTracks(row)).
    reduce((hash, object) => { hash[object.id] = object.tracks; return hash; }, {});
  playlists.forEach(playlist => playlistTracks[playlist.id] = playlistTracks[playlist.id] || []);
  this.playlistsHash = playlists.reduce(toHash, {});
  var trackChanges = data["track_user_changes"];

  var sortSearchName = function(i1, i2) {
    if (i1.searchName == i2.searchName) { return 0; }
    else if (i1.searchName > i2.searchName) { return 1; }
    else { return -1; }
  }
  this.tracksArr = data["tracks"].map(row => new Track(row, artists, albums, genres)).sort(sortSearchName);
  this.tracksHash = this.tracksArr.reduce(toHash, {});

  this.ratings = new Ratings(this.tracksHash, trackChanges);

  // inputs
  var rowsPerPage = 43;
  var audioSlots = 3; // go add more <audio> tags to play.html if you change this
  var colDescriptions = [
      { "name": "Name",   "data": "name", "sort": ["sortName"] },
      { "name": "Time",   "data": "time", "type": "numeric", "sort": ["duration"] , "typeToShow": false, "filter": false },
      { "name": "Artist", "data": "artist", "sort": ["sortArtist"] },
      { "name": "Album",  "data": "album", "sort": ["sortAlbumArtist", "year", "sortAlbum", "disc", "track"], "typeToShow": false },
      { "name": "Genre",  "data": "genre", "typeToShow": false },
      { "name": "Year",   "data": "year", "type": "numeric", "typeToShow": false, "filter": false  },
      { "name": "Plays",  "data": "playCount", "type": "numeric", "typeToShow": false, "filter": false },
      { "name": "Rating", "data": "rating", "type": "numeric", "typeToShow": false, "filter": false, "initializer": this.ratings.initialize.bind(this.ratings), "formatter": this.ratings.format.bind(this.ratings) }
  ];

  // initialize
  this.settings = new PersistentSettings();
  this.trackTable = new TrackTable(colDescriptions, rowsPerPage, trackChanges);
  this.controls = new Controls(this.settings);
  this.remoteControl = new RemoteControl(this.settings);
  this.pagination = new Pagination();
  this.filterBar = new FilterBar();
  this.playlistTree = new PlaylistTree(playlists, this.playlistsHash, this.settings);
  this.keyboard = new Keyboard();
  this.filter = new Filter(this.tracksHash, colDescriptions);
  this.sorter = new Sorter(this.tracksHash, colDescriptions);
  this.playlistDisplayManager = new PlaylistDisplayManager(this.playlistsHash, playlistTracks, this.tracksHash, colDescriptions);
  this.playlistControlManager = new PlaylistControlManager(this.tracksHash, audioSlots);
  this.trackDisplayManager = new TrackDisplayManager(this.tracksHash, colDescriptions, rowsPerPage, genres);
  this.audio = new Audio(audioSlots, trackChanges);

  // hook up events
  this.trackTable.setCallbacks(this.sorter.sortChanged.bind(this.sorter),
                               this.trackDisplayManager.trackClicked.bind(this.trackDisplayManager),
                               this.trackDisplayManager.playTrack.bind(this.trackDisplayManager),
                               this.trackDisplayManager.playTrackNext.bind(this.trackDisplayManager),
                               this.trackDisplayManager.downloadTrack.bind(this.trackDisplayManager),
                               this.trackDisplayManager.trackInfo.bind(this.trackDisplayManager));
  this.controls.setCallbacks(this.playlistControlManager.prev.bind(this.playlistControlManager),
                             this.playlistControlManager.playPause.bind(this.playlistControlManager),
                             this.playlistControlManager.next.bind(this.playlistControlManager),
                             this.playlistControlManager.shuffleChanged.bind(this.playlistControlManager),
                             this.playlistControlManager.repeatChanged.bind(this.playlistControlManager),
                             this.audio.volumeChanged.bind(this.audio));
  this.remoteControl.setCallbacks(this.controls.prevClick.bind(this.controls),
                                  this.controls.playPauseClick.bind(this.controls),
                                  this.controls.nextCallback.bind(this.controls));
  this.pagination.setCallbacks(this.trackDisplayManager.pageChanged.bind(this.trackDisplayManager));
  this.filterBar.setCallbacks(this.filter.filterChanged.bind(this.filter),
                              this.filter.filterCleared.bind(this.filter));
  this.playlistTree.setCallbacks(this.playlistDisplayManager.playlistChanged.bind(this.playlistDisplayManager));
  this.keyboard.setCallbacks(this.playlistControlManager.prev.bind(this.playlistControlManager),
                             this.playlistControlManager.playPause.bind(this.playlistControlManager),
                             this.playlistControlManager.next.bind(this.playlistControlManager),
                             this.controls.volumeUp.bind(this.controls),
                             this.controls.volumeDown.bind(this.controls),
                             this.trackDisplayManager.typeToShow.bind(this.trackDisplayManager));
  this.filter.setCallbacks(this.playlistDisplayManager.displayChanged.bind(this.playlistDisplayManager));
  this.sorter.setCallbacks(this.playlistDisplayManager.displayChanged.bind(this.playlistDisplayManager));
  this.playlistDisplayManager.setCallbacks(this.filter.filterTrackList.bind(this.filter),
                                           this.sorter.sortTrackList.bind(this.sorter),
                                           this.trackDisplayManager.tracksChanged.bind(this.trackDisplayManager),
                                           this.trackDisplayManager.nowPlayingIdChanged.bind(this.trackDisplayManager),
                                           this.playlistControlManager.nowPlayingTracksChanged.bind(this.playlistControlManager),
                                           this.filterBar.clearFilter.bind(this.filterBar),
                                           this.playlistTree.showPlaylist.bind(this.playlistTree));
  this.playlistControlManager.setCallbacks(this.playlistDisplayManager.nowPlayingIdChanged.bind(this.playlistDisplayManager),
                                           this.controls.isPlayingChanged.bind(this.controls),
                                           this.audio.loadTracks.bind(this.audio),
                                           this.audio.play.bind(this.audio),
                                           this.audio.pause.bind(this.audio),
                                           this.audio.rewindCurrentTrack.bind(this.audio));
  this.trackDisplayManager.setCallbacks(this.trackTable.tracksChanged.bind(this.trackTable),
                                        this.pagination.numPagesChanged.bind(this.pagination),
                                        this.pagination.changedToPage.bind(this.pagination),
                                        this.sorter.sortForTypeToShowList.bind(this.sorter),
                                        this.playlistDisplayManager.playTrack.bind(this.playlistDisplayManager),
                                        this.playlistControlManager.playTrackNext.bind(this.playlistControlManager));
  this.audio.setCallbacks(this.playlistControlManager.next.bind(this.playlistControlManager),
                          this.playlistDisplayManager.showNowPlayingTrack.bind(this.playlistDisplayManager));

  // and off we go
  this.playlistTree.start();
  this.controls.start();
}

var streamer;
$(window).load(function() {
  $.getJSON("/data.json", function(data) {
    streamer = new Streamer(data);
  });
});
