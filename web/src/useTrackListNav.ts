import {
  KeyboardEvent,
  RefObject,
  useCallback,
  useMemo,
  useState,
} from "react";
import { Track } from "./Library";
import { RevealView } from "./State";
import { useDetailTrackReveal } from "./Reveal";
import { useFollowPlaying } from "./FollowPlaying";
import { useTypeToSearch } from "./useTypeToSearch";

// keyboard selection and type-to-search for a scrollable track list: arrow keys
// walk the flattened track order and printable keys jump to the nearest name,
// scrolling the matched row into view by its data-track-id
export function useTrackListNav(
  flatTracks: Track[],
  containerRef: RefObject<HTMLElement | null>,
  onPlayTrack: (track: Track) => void,
  revealView: RevealView
) {
  const [selectedTrackId, setSelectedTrackId] = useState<string | null>(null);

  // when a "go to" lands on this view and the target track is one of ours,
  // select it, scroll it to the middle, and consume the request. the parent
  // view has already selected the right artist/album so it's in flatTracks
  useDetailTrackReveal(
    revealView,
    flatTracks,
    containerRef,
    setSelectedTrackId
  );

  // follow playback as it moves: the selection is the user's own cursor, so this
  // only scrolls. the query misses when the playing track isn't in this
  // artist/album, and then there is nothing to scroll to
  const scrollToPlaying = useCallback(
    (trackId: string) => {
      containerRef.current
        ?.querySelector(`[data-track-id="${CSS.escape(trackId)}"]`)
        ?.scrollIntoView({ block: "center" });
    },
    [containerRef]
  );
  useFollowPlaying(scrollToPlaying);

  const selectIndex = useCallback(
    (index: number) => {
      const track = flatTracks[index];
      if (!track) {
        return;
      }
      setSelectedTrackId(track.id);
      containerRef.current
        ?.querySelector(`[data-track-id="${CSS.escape(track.id)}"]`)
        ?.scrollIntoView({ block: "nearest" });
    },
    [flatTracks, containerRef]
  );

  const searchNames = useMemo(
    () => flatTracks.map((track) => track.name),
    [flatTracks]
  );
  const handleTypeSearch = useTypeToSearch(searchNames, selectIndex);

  const handleKeyDown = useCallback(
    (event: KeyboardEvent) => {
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        const current = flatTracks.findIndex(
          (track) => track.id === selectedTrackId
        );
        const delta = event.key === "ArrowDown" ? 1 : -1;
        selectIndex(current === -1 ? 0 : current + delta);
        return;
      }
      if (event.key === "Enter") {
        const track = flatTracks.find((t) => t.id === selectedTrackId);
        if (track) {
          event.preventDefault();
          onPlayTrack(track);
        }
        return;
      }
      if (handleTypeSearch(event)) {
        event.preventDefault();
      }
    },
    [flatTracks, selectedTrackId, selectIndex, handleTypeSearch, onPlayTrack]
  );

  return { selectedTrackId, setSelectedTrackId, handleKeyDown };
}
