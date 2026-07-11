import { Playlist } from "./Library";

// one entry in the "show in playlist" submenu: the playlist's id and name
export interface PlaylistOption {
  id: string;
  name: string;
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
