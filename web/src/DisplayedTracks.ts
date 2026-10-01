import { useLayoutEffect } from "react";
import { atom, useSetAtom } from "jotai";
import { Track } from "./Library";

export interface DisplayedTracks {
  source: string;
  tracks: Track[];
}

export const displayedTracksAtom = atom<DisplayedTracks | null>(null);

export function useDisplayedTracks(source: string, tracks: Track[]) {
  const setDisplayedTracks = useSetAtom(displayedTracksAtom);

  useLayoutEffect(() => {
    const display = { source, tracks };
    setDisplayedTracks(display);
    return () => {
      setDisplayedTracks((current) => (current === display ? null : current));
    };
  }, [source, tracks, setDisplayedTracks]);
}
