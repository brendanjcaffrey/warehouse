import { Track } from "./Library";
import { FILTER_KEYS } from "./TrackTableColumns";

export function FilterTrackList(
  tracks: Track[],
  trackIndexes: number[],
  searchValue: string
): number[] {
  const words = searchValue
    .toLowerCase()
    .split(" ")
    .filter((word) => word.length > 0);

  return trackIndexes.filter((trackIdx) => {
    const track = tracks[trackIdx];
    return words.every((word) => {
      return (
        FILTER_KEYS.find((keyName) => {
          return track[keyName].toLowerCase().indexOf(word) !== -1;
        }) !== undefined
      );
    });
  });
}
