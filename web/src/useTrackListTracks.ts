import { useEffect, useState } from "react";
import { useAtomValue } from "jotai";
import library, { Track } from "./Library";
import { updatedTrackAtom } from "./State";

// loads the tracks the songs and playlist views show: the whole library when no
// playlist is given, otherwise just that playlist's tracks. reloads when the
// playlist changes so navigating between playlists swaps the list, and patches a
// track in place when it's edited so ratings and edits show without a reload
export function useTrackListTracks(playlistId?: string): Track[] {
  const [tracks, setTracks] = useState<Track[]>([]);
  const updatedTrack = useAtomValue(updatedTrackAtom);

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

  useEffect(() => {
    if (!updatedTrack) {
      return;
    }
    setTracks((prev) =>
      prev.map((track) => (track.id === updatedTrack.id ? updatedTrack : track))
    );
  }, [updatedTrack]);

  return tracks;
}
