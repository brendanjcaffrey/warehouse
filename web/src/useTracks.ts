import { useEffect, useState } from "react";
import library, { Track } from "./Library";

// loads every track out of the library once on mount
export function useTracks(): Track[] {
  const [tracks, setTracks] = useState<Track[]>([]);

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

  return tracks;
}
