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

export function UpdateTrackTableState(
  oldState: TrackTableState,
  event: IconWidthsChanged | TracksChanged | SortChanged | FilterChanged
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
  }

  if (
    event.type === UpdateType.IconWidthsChanged ||
    event.type === UpdateType.TracksChanged
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

  // if it's not just a filter change, sort the tracks
  if (event.type !== UpdateType.FilterChanged) {
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

  if (newState.filterText === "") {
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
