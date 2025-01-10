import { Track } from "./Library";
import { COLUMNS, GetColumnWidths } from "./TrackTableColumns";
import { IconWidths } from "./MeasureIconWidths";
import { SortState, SortTracks } from "./TrackTableSort";
import { FilterTrackList } from "./TrackTableFilter";
import { TypeToShowEntry, BuildTypeToShowList } from "./TrackTableTypeToShow";
import { DEFAULT_COLUMN_WIDTH } from "./TrackTableConstants";

export interface TrackTableState {
  iconWidths: IconWidths;
  playlistId: string;
  tracks: Track[];
  columnWidths: number[];

  sortState: SortState;
  sortIndexes: number[];

  filterText: string;
  sortFilteredIndexes: number[];

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
  sortIndexes: [],

  filterText: "",
  sortFilteredIndexes: [],

  typeToShowList: [],
};

export enum UpdateType {
  IconWidthsChanged,
  TracksChanged,
  SortChanged,
  FilterChanged,
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
};

export type SortChanged = {
  type: UpdateType.SortChanged;
  sortState: SortState;
};

export type FilterChanged = {
  type: UpdateType.FilterChanged;
  filterText: string;
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
      break;
    case UpdateType.SortChanged:
      newState.sortState = event.sortState;
      break;
    case UpdateType.FilterChanged:
      newState.filterText = event.filterText;
      break;
    case UpdateType.TrackUpdated: {
      const trackIndex = newState.tracks.findIndex(
        (track) => track.id === event.track.id
      );
      if (trackIndex !== -1) {
        newState.tracks[trackIndex] = event.track;
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
      newState.sortIndexes = allIndexes;
    } else {
      const column = COLUMNS.find(
        (column) => column.id === newState.sortState.columnId
      );

      newState.sortIndexes = SortTracks(
        newState.tracks,
        allIndexes,
        column!,
        newState.sortState.ascending
      );
    }
  }

  // we don't re-filter on a single track edit either
  if (newState.filterText === "" || event.type === UpdateType.TracksChanged) {
    newState.sortFilteredIndexes = newState.sortIndexes.slice();
  } else {
    newState.sortFilteredIndexes = FilterTrackList(
      newState.tracks,
      newState.sortIndexes,
      newState.filterText
    );
  }

  const column = COLUMNS.find(
    (column) => column.id === newState.sortState.columnId
  );
  newState.typeToShowList = BuildTypeToShowList(
    newState.tracks,
    newState.sortFilteredIndexes,
    column || COLUMNS[0]
  );

  return newState;
}
