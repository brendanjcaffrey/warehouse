var PlaylistTree = function(playlists, playlistsHash, settings) {
  this.openFolderIcon = "ion-md-arrow-dropdown";
  this.closedFolderIcon = "ion-md-arrow-dropright";

  this.playlistsHash = playlistsHash;
  this.settings = settings;
  this.resolveTree(playlists);
  this.buildUI("#playlists");
}

PlaylistTree.prototype.setCallbacks = function(playlistChangedCallback) {
  this.playlistChangedCallback = playlistChangedCallback;
}

PlaylistTree.prototype.start = function(playlists) {
  this.playlistChangedCallback(this.tree[0].id);
}

PlaylistTree.prototype.resolveTree = function(playlists) {
  var sortName = (i1, i2) => {
    if (i1.isLibrary == i2.isLibrary) {}
    else if (i1.isLibrary) { return -1; }
    else if (i2.isLibrary) { return 1; }

    var i1IsFolder = i1.children.length != 0;
    var i2IsFolder = i2.children.length != 0;
    if (i1IsFolder == i2IsFolder) {}
    else if (i1IsFolder) { return -1; }
    else if (i2IsFolder) { return 1; }

    if (i1.name == i2.name) { return 0; }
    else if (i1.name > i2.name) { return 1; }
    else { return -1; }
  }

  var resolvePlaylistTreeStep = (playlists, tree, parentId) => {
    for (var i = 0; i < playlists.length; ++i) {
      if (playlists[i].parentId == parentId) {
        tree.push(playlists[i]);
        resolvePlaylistTreeStep(playlists, playlists[i].children, playlists[i].id);
      }
    }
    tree.sort(sortName);
  }

  this.tree = [];
  resolvePlaylistTreeStep(playlists, this.tree, "");
}

PlaylistTree.prototype.buildUI = function(id) {
  var ulClasses = 'nav nav-pills nav-stacked';

  var buildPlaylistMenuStep = (children, parentElement) => {
    children.forEach((playlist, idx, arr) => {
      var arrow = this.closedFolderIcon + " spacer";
      var icon = "ion-ios-list";
      var isActive = false;
      var isFolder = playlist.children.length > 0;
      var folderIsOpen = isFolder && this.settings.getFolderOpen(playlist.id);

      if (playlist.isLibrary) { icon = "ion-ios-musical-notes"; isActive = true; }
      if (isFolder) {
        arrow = folderIsOpen ? this.openFolderIcon : this.closedFolderIcon;
        icon = "ion-md-folder-open";
      }

      parentElement.append('<li id="playlist' + playlist.id + '" data-playlist-id="' + playlist.id + '" data-is-folder="' + (isFolder ? '1' : '0') + '"' +
          (isActive ? ' class="active"' : '') + '><a href="#"><i class="arrow icon ' + arrow + '" /><i class="icon marker ' +
          icon + '" />' + playlist.name + "</a></li>");

      var currentLi = parentElement.children("li").last();
      currentLi.on("click", (e) => {
        var li = $(e.delegateTarget);
        var playlistId = li.attr("data-playlist-id");
        var target = $(e.target);
        if (target.hasClass("arrow") && li.attr("data-is-folder") == "1") {
          this.toggleFolder(playlistId, li, target);
        } else {
          $(id + " li.active").removeClass("active");
          li.addClass("active");

          this.playlistChangedCallback(playlistId);
        }
      });

      if (isFolder) {
        var hiddenIfClosed = folderIsOpen ? "" : 'class="hidden" ';
        parentElement.append('<li ' + hiddenIfClosed + 'id="childrenof' + playlist.id + '"><ul class="' + ulClasses + '"></ul></li>');
        buildPlaylistMenuStep(playlist.children, parentElement.children("li").last().children("ul"));
      }
    });
  };

  $(id).append('<ul class="' + ulClasses + '"></ul>');
  buildPlaylistMenuStep(this.tree, $(id).children("ul"));
}

PlaylistTree.prototype.showPlaylist = function(id) {
  $("#playlist" + id).click();

  var playlist = this.playlistsHash[id];
  while (playlist.parentId != "") {
    if ($("#playlist" + playlist.parentId + " i.arrow").hasClass(this.closedFolderIcon)) {
      $("#playlist" + playlist.parentId + " i.arrow").click();
    }
    playlist = this.playlistsHash[playlist.parentId];
  }
}

PlaylistTree.prototype.toggleFolder = function(id, li, arrow) {
  var isClosed = arrow.hasClass(this.closedFolderIcon);
  if (isClosed) {
    this.settings.setFolderOpen(id);
    arrow.removeClass(this.closedFolderIcon).addClass(this.openFolderIcon);
    $("#childrenof" + id).removeClass("hidden");
  } else {
    this.settings.setFolderClosed(id);
    arrow.removeClass(this.openFolderIcon).addClass(this.closedFolderIcon);
    $("#childrenof" + id).addClass("hidden");
  }
}

