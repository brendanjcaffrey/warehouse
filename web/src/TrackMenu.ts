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

// the filename to save a track's music file under when downloading it, as
// "artist - name" with the source file's extension preserved
export function downloadFilename(
  track: Pick<Track, "artistName" | "name" | "musicFilename">
): string {
  const parts = track.musicFilename.split(".");
  const extension = parts.length > 1 ? `.${parts[parts.length - 1]}` : "";
  return `${track.artistName} - ${track.name}${extension}`;
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

export interface MenuRect {
  left: number;
  right: number;
  top: number;
  bottom: number;
}

// where a context menu opened at a click point should sit so it stays on
// screen. prefer down and to the right but check if that would be of screen.
export function menuPosition(
  click: { x: number; y: number },
  size: { width: number; height: number },
  viewport: { width: number; height: number },
  margin = 8
): { x: number; y: number; maxHeight?: number } {
  const available = Math.max(0, viewport.height - margin * 2);
  return {
    x: menuAxis(click.x, size.width, viewport.width, margin),
    y: menuAxis(click.y, size.height, viewport.height, margin),
    maxHeight: size.height > available ? available : undefined,
  };
}

// one axis of menuPosition: after the point, before it, or clamped to fit
function menuAxis(
  at: number,
  size: number,
  viewport: number,
  margin: number
): number {
  if (at + size <= viewport - margin) {
    return at;
  }
  if (at - size >= margin) {
    return at - size;
  }
  return Math.max(margin, viewport - margin - size);
}

// where a submenu opened at a row should sit so it stays on screen. prefer down and to
// the right but check if that would be of screen.
export function submenuPlacement(
  anchor: MenuRect,
  size: { width: number; height: number },
  viewport: { width: number; height: number },
  margin = 8
): { left: boolean; up: boolean } {
  const overflowsRight = anchor.right + size.width > viewport.width - margin;
  const fitsLeft = anchor.left - size.width >= margin;
  const overflowsBottom = anchor.top + size.height > viewport.height - margin;
  const fitsUp = anchor.bottom - size.height >= margin;
  return {
    left: overflowsRight && fitsLeft,
    up: overflowsBottom && fitsUp,
  };
}
