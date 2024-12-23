import { Track } from "./Library";
import { FILTER_KEYS } from "./TrackTableColumns";

export function FilterTrackList(
  tracks: Track[],
  trackIndexes: number[],
  filterText: string
): number[] {
  const words = filterText
    .toLowerCase()
    .split(" ")
    .filter((word) => word.length > 0);

  return trackIndexes.filter((trackIdx) => {
    const track = tracks[trackIdx];
    // every word must be found in at least one of the filter keys
    return words.every((word) => {
      return (
        FILTER_KEYS.find((keyName) => {
          return track[keyName].toLowerCase().indexOf(word) !== -1;
        }) !== undefined
      );
    });
  });
}
