import { useEffect, useState } from "react";
import { useAtomValue } from "jotai";
import library, { Track } from "./Library";
import { updatedTrackAtom } from "./State";

// loads every track out of the library once on mount, patching a track in place
// when it's edited so ratings and edits show without a full reload
export function useTracks(): Track[] {
  const [tracks, setTracks] = useState<Track[]>([]);
  const updatedTrack = useAtomValue(updatedTrackAtom);

  useEffect(() => {
    let cancelled = false;
    library()
      .getAllTracks()
      .then((result) => {
        if (!cancelled && result) {
          setTracks(result);
        }
      });
    return () => {
      cancelled = true;
    };
  }, []);

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
