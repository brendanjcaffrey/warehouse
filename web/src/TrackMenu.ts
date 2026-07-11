import { Playlist, Track } from "./Library";
import { albumKeyForTrack } from "./AlbumList";
import { RevealView } from "./State";

// one entry in the "show in playlist" submenu: the playlist's id and name
export interface PlaylistOption {
  id: string;
  name: string;
}

// one "go to ..." entry in the track menu: where it navigates and the reveal it
// asks that view to perform
export interface GotoTarget {
  kind: "song" | "artist" | "album";
  label: string;
  view: RevealView;
  path: string;
  selectionId?: string;
}

// the "go to song / artist / album" entries a track offers from a given view.
// the entry for the view we're already in is dropped, and artist/album are
// dropped when the track has no artist/album to land on
export function trackGotoTargets(
  track: Pick<Track, "artistName" | "albumName" | "albumArtistName">,
  pathname: string
): GotoTarget[] {
  const targets: GotoTarget[] = [];
  if (pathname !== "/songs") {
    targets.push({
      kind: "song",
      label: "Go to Song",
      view: "songs",
      path: "/songs",
    });
  }
  if (track.artistName && pathname !== "/artists") {
    targets.push({
      kind: "artist",
      label: "Go to Artist",
      view: "artists",
      path: "/artists",
      selectionId: track.artistName,
    });
  }
  if (track.albumName && pathname !== "/albums") {
    targets.push({
      kind: "album",
      label: "Go to Album",
      view: "albums",
      path: "/albums",
      selectionId: albumKeyForTrack(track),
    });
  }
  return targets;
}

// the playlists a track belongs to, resolved to names and sorted, for the "show
// in playlist" submenu. the library isn't a real playlist so it's dropped, and
// when we're already viewing a playlist that one is left out too, so the submenu
// only ever offers somewhere else to go
export function trackPlaylistOptions(
  track: { playlistIds: string[] },
  playlists: Playlist[],
  currentPlaylistId?: string
): PlaylistOption[] {
  const byId = new Map(playlists.map((playlist) => [playlist.id, playlist]));
  const options: PlaylistOption[] = [];
  for (const id of track.playlistIds) {
    if (id === currentPlaylistId) {
      continue;
    }
    const playlist = byId.get(id);
    if (!playlist || playlist.isLibrary) {
      continue;
    }
    options.push({ id: playlist.id, name: playlist.name });
  }
  options.sort((a, b) => a.name.localeCompare(b.name));
  return options;
}
