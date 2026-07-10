import { useEffect, useState } from "react";
import library, { Playlist } from "./Library";

// loads every playlist out of the library once on mount
export function usePlaylists(): Playlist[] {
  const [playlists, setPlaylists] = useState<Playlist[]>([]);

  useEffect(() => {
    let cancelled = false;
    library()
      .getAllPlaylists()
      .then((result) => {
        if (!cancelled && result) {
          setPlaylists(result);
        }
      });
    return () => {
      cancelled = true;
    };
  }, []);

  return playlists;
}
