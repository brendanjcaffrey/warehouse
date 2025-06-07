import { Track } from "./Library";
import { COLUMNS, GetColumnWidths } from "./TrackTableColumns";
import { IconWidths } from "./MeasureIconWidths";
import { PrecomputeTrackSort, SortState, SortTracks } from "./TrackTableSort";
import { FilterTrackList } from "./TrackTableFilter";
import { TypeToShowEntry, BuildTypeToShowList } from "./TrackTableTypeToShow";
import { DEFAULT_COLUMN_WIDTH } from "./TrackTableConstants";
import { PlaylistEntry } from "./Types";

export interface TrackTableState {
  iconWidths: IconWidths;
  playlistId: string;
  tracks: Track[];
  columnWidths: number[];

  sortState: SortState;
  // tracks in sorted order, these are indexes into `tracks`
  sortedPlaylistOffsets: number[];

  filterText: string;
  // sorted tracks after applying the filter text, these are indexes into `tracks`
  sortedFilteredPlaylistOffsets: number[];

  // selected track, an index into tracks
  selectedPlaylistEntry: PlaylistEntry | undefined;

  typeToShowList: TypeToShowEntry[];
}

export const DEFAULT_STATE: TrackTableState = {
  iconWidths: { star: 0, upwardArrow: 0, volumeUp: 0 },
  playlistId: "",
  tracks: [],
  columnWidths: COLUMNS.map(() => DEFAULT_COLUMN_WIDTH),

  sortState: {
    columnId: null,
    ascending: true,
  },
  sortedPlaylistOffsets: [],

  filterText: "",
  sortedFilteredPlaylistOffsets: [],

  selectedPlaylistEntry: undefined,

  typeToShowList: [],
};

export enum UpdateType {
  IconWidthsChanged,
  TracksChanged,
  SortChanged,
  FilterChanged,
  SelectedPlaylistOffsetChanged,
  TrackUpdated,
}

export type IconWidthsChanged = {
  type: UpdateType.IconWidthsChanged;
  iconWidths: IconWidths;
};

export type TracksChanged = {
  type: UpdateType.TracksChanged;
  playlistId: string;
  tracks: Track[];
  selectedPlaylistOffset: number | undefined;
};

export type SortChanged = {
  type: UpdateType.SortChanged;
  sortState: SortState;
};

export type FilterChanged = {
  type: UpdateType.FilterChanged;
  filterText: string;
};

export type SelectedPlaylistOffsetChanged = {
  type: UpdateType.SelectedPlaylistOffsetChanged;
  playlistOffset: number;
};

export type TrackUpdated = {
  type: UpdateType.TrackUpdated;
  track: Track;
};

export function UpdateTrackTableState(
  oldState: TrackTableState,
  event:
    | IconWidthsChanged
    | TracksChanged
    | SortChanged
    | FilterChanged
    | SelectedPlaylistOffsetChanged
    | TrackUpdated
): TrackTableState {
  const newState = { ...oldState };
  switch (event.type) {
    case UpdateType.IconWidthsChanged:
      newState.iconWidths = event.iconWidths;
      break;
    case UpdateType.TracksChanged:
      newState.playlistId = event.playlistId;
      newState.tracks = event.tracks;
      if (event.selectedPlaylistOffset) {
        newState.selectedPlaylistEntry = {
          playlistId: newState.playlistId,
          playlistOffset: event.selectedPlaylistOffset,
        };
      }
      break;
    case UpdateType.SortChanged:
      newState.sortState = event.sortState;
      break;
    case UpdateType.FilterChanged:
      newState.filterText = event.filterText;
      break;
    case UpdateType.SelectedPlaylistOffsetChanged:
      newState.selectedPlaylistEntry = {
        playlistId: newState.playlistId,
        playlistOffset: event.playlistOffset,
      };
      return newState; // no need to do anything else
    case UpdateType.TrackUpdated: {
      const trackIndex = newState.tracks.findIndex(
        (track) => track.id === event.track.id
      );
      if (trackIndex !== -1) {
        const track = newState.tracks[trackIndex];
        PrecomputeTrackSort(event.track);
        newState.tracks[trackIndex] = track;
      }
      break;
    }
  }

  if (
    event.type === UpdateType.IconWidthsChanged ||
    event.type === UpdateType.TracksChanged ||
    event.type === UpdateType.TrackUpdated
  ) {
    newState.columnWidths = GetColumnWidths(
      newState.tracks,
      newState.iconWidths
    );
  }

  // don't bother sorting/filterng if this is all that changed
  if (event.type === UpdateType.IconWidthsChanged) {
    return newState;
  }

  // on a filter change, we don't need to re-sort the list. when a single track is updated,
  // we deliberately don't re-sort the list to maintain the current order so the row doesn't
  // jump around if there's a typo etc
  if (
    event.type !== UpdateType.FilterChanged &&
    event.type !== UpdateType.TrackUpdated
  ) {
    const allIndexes = newState.tracks.map((_, i) => i);
    if (newState.sortState.columnId === null) {
      newState.sortedPlaylistOffsets = allIndexes;
    } else {
      const column = COLUMNS.find(
        (column) => column.id === newState.sortState.columnId
      );

      newState.sortedPlaylistOffsets = SortTracks(
        newState.tracks,
        allIndexes,
        column!,
        newState.sortState.ascending
      );
    }
  }

  // we don't re-filter on a single track edit either
  if (newState.filterText === "" || event.type === UpdateType.TrackUpdated) {
    newState.sortedFilteredPlaylistOffsets =
      newState.sortedPlaylistOffsets.slice();
  } else {
    newState.sortedFilteredPlaylistOffsets = FilterTrackList(
      newState.tracks,
      newState.sortedPlaylistOffsets,
      newState.filterText
    );
  }

  const column = COLUMNS.find(
    (column) => column.id === newState.sortState.columnId
  );
  newState.typeToShowList = BuildTypeToShowList(
    newState.tracks,
    newState.sortedFilteredPlaylistOffsets,
    column || COLUMNS[0]
  );

  return newState;
}
