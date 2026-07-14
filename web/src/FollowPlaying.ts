import { useEffect, useRef } from "react";
import { useAtomValue } from "jotai";
import { playingTrackAtom } from "./State";

// keeps a track list following playback: whenever the playing track changes, be
// it a song ending, a next/prev, or a jump around the queue, the list scrolls to
// the new one so the row carrying the playing marker stays on screen.
//
// the first track a view sees is deliberately not scrolled to. mounting a view,
// or landing on one from a "go to", should leave the list where the user asked
// to be rather than yanking it to whatever happens to be playing; only a change
// after that is playback moving on. onScroll takes the track id and is expected
// to do nothing when this list doesn't hold that track
export function useFollowPlaying(onScroll: (trackId: string) => void) {
  const playingTrack = useAtomValue(playingTrackAtom);
  const trackId = playingTrack?.track.id;

  // undefined is a real state, nothing is playing, so a separate flag is what
  // tells "not observed yet" apart from it. that way a view mounted while
  // stopped still follows the first track played into it
  const observed = useRef(false);
  const lastTrackId = useRef<string | undefined>(undefined);

  useEffect(() => {
    if (!observed.current) {
      observed.current = true;
      lastTrackId.current = trackId;
      return;
    }
    if (trackId === lastTrackId.current) {
      return;
    }
    lastTrackId.current = trackId;
    // playback stopping leaves the list where it is rather than scrolling
    if (trackId) {
      onScroll(trackId);
    }
  }, [trackId, onScroll]);
}
