import { useEffect, useState } from "react";
import library, { Track } from "./Library";

// loads the tracks the songs and playlist views show: the whole library when no
// playlist is given, otherwise just that playlist's tracks. reloads when the
// playlist changes so navigating between playlists swaps the list
export function useTrackListTracks(playlistId?: string): Track[] {
  const [tracks, setTracks] = useState<Track[]>([]);

  useEffect(() => {
    let cancelled = false;
    const load = playlistId
      ? library().getAllPlaylistTracks(playlistId)
      : library().getAllTracks();
    load.then((result) => {
      if (!cancelled && result) {
        setTracks(result);
      }
    });
    return () => {
      cancelled = true;
    };
  }, [playlistId]);

  return tracks;
}
