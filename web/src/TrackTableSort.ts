import { Track } from "./Library";
import { DisplayedTrackKeys } from "./TrackTableColumns";

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
