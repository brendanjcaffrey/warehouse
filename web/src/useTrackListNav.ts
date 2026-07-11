import {
  KeyboardEvent,
  RefObject,
  useCallback,
  useMemo,
  useState,
} from "react";
import { Track } from "./Library";
import { useTypeToSearch } from "./useTypeToSearch";

// keyboard selection and type-to-search for a scrollable track list: arrow keys
// walk the flattened track order and printable keys jump to the nearest name,
// scrolling the matched row into view by its data-track-id
export function useTrackListNav(
  flatTracks: Track[],
  containerRef: RefObject<HTMLElement | null>
) {
  const [selectedTrackId, setSelectedTrackId] = useState<string | null>(null);

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
      if (handleTypeSearch(event)) {
        event.preventDefault();
      }
    },
    [flatTracks, selectedTrackId, selectIndex, handleTypeSearch]
  );

  return { selectedTrackId, setSelectedTrackId, handleKeyDown };
}
