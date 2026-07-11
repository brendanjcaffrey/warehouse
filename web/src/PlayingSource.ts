import { Playlist, Track } from "./Library";
import { RevealTarget } from "./State";
import { albumKeyForTrack } from "./AlbumList";

// where the now playing track is playing from, resolved from the source string
// the player stamped on it. reveal drives "return to source" and label names the
// source for the subtitle
export interface PlayingSource {
  reveal: RevealTarget;
  path: string;
  label: string;
}

// the songs view plays under this sentinel, and the album/artist views prefix
// their source so it survives round-tripping through the queue
const ALBUM_PREFIX = "album:";
const ARTIST_PREFIX = "artist:";

// decodes the player's source string into the view it came from. anything that
// isn't the library or an album/artist scope is a playlist id, resolved to its
// name; an unknown id yields null so the caller can hide the control
export function resolvePlayingSource(
  source: string,
  track: Track,
  playlists: Playlist[]
): PlayingSource | null {
  if (source === "library") {
    return {
      reveal: { trackId: track.id, view: "songs" },
      path: "/songs",
      label: "Songs",
    };
  }
  if (source.startsWith(ARTIST_PREFIX)) {
    const name = source.slice(ARTIST_PREFIX.length);
    return {
      reveal: { trackId: track.id, view: "artists", selectionId: name },
      path: "/artists",
      label: name,
    };
  }
  if (source.startsWith(ALBUM_PREFIX)) {
    const name = source.slice(ALBUM_PREFIX.length);
    return {
      reveal: {
        trackId: track.id,
        view: "albums",
        selectionId: albumKeyForTrack(track),
      },
      path: "/albums",
      label: name,
    };
  }
  const playlist = playlists.find((p) => p.id === source);
  if (!playlist) {
    return null;
  }
  return {
    reveal: { trackId: track.id, view: "playlist", selectionId: playlist.id },
    path: `/playlists/${playlist.id}`,
    label: playlist.name,
  };
}
