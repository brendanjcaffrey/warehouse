import { Track } from "./Library";
import { Column, DisplayedTrackKeys } from "./TrackTableColumns";

export interface SortState {
  columnId: keyof DisplayedTrackKeys | null;
  ascending: boolean;
}

// precomputng all this takes sorting a ~10k track list from ~300ms to ~5ms
export function PrecomputeTrackSort(track: Track) {
  track.sortName =
    track.sortName === ""
      ? track.name.toLowerCase()
      : track.sortName.toLowerCase();
  track.artistSortName =
    track.artistSortName === ""
      ? track.artistName.toLowerCase()
      : track.artistSortName.toLowerCase();
  track.albumArtistSortName =
    track.albumArtistSortName === ""
      ? track.albumArtistName.toLowerCase()
      : track.albumArtistSortName.toLowerCase();
  track.albumSortName =
    track.albumSortName === ""
      ? track.albumName.toLowerCase()
      : track.albumSortName.toLowerCase();
}

export function SortTracks(
  tracks: Track[],
  allIndexes: number[],
  column: Column,
  ascending: boolean
) {
  const sortedIndexes = allIndexes.sort((a, b) => {
    const trackA = tracks[a];
    const trackB = tracks[b];
    for (const key of column.sortKeys) {
      const valueA = trackA[key];
      const valueB = trackB[key];
      if (valueA !== valueB) {
        return valueA! < valueB! ? -1 : 1;
      }
    }
    return 0;
  });
  if (!ascending) {
    sortedIndexes.reverse();
  }
  return sortedIndexes;
}
