import { useState, useEffect, useRef, useReducer, useCallback } from "react";
import { useAtomValue } from "jotai";
import AutoSizer from "react-virtualized-auto-sizer";
import { VariableSizeGrid } from "react-window";
import { useDebouncedAtomValue } from "./useDebouncedAtomValue";
import { useDebouncedTypedInput } from "./useDebouncedTypedInput";
import library from "./Library";
import { selectedPlaylistAtom, searchAtom } from "./State";
import { IconWidths, MeasureIconWidths } from "./MeasureIconWidths";
import { TrackTableContext } from "./TrackTableContext";
import {
  UpdateTrackTableState,
  DEFAULT_STATE,
  UpdateType,
} from "./TrackTableState";
import { TrackTableStickyHeaderGrid } from "./TrackTableStickyHeader";
import { COLUMNS } from "./TrackTableColumns";
import { TrackTableCell } from "./TrackTableCell";
import { SortState, PrecomputeTrackSort } from "./TrackTableSort";
import { BinarySearchTypeToShowList } from "./TrackTableTypeToShow";
import { ROW_HEIGHT } from "./TrackTableConstants";

function TrackTable() {
  const gridRef = useRef<VariableSizeGrid>(null);

  const selectedPlaylist = useAtomValue(selectedPlaylistAtom);
  const [state, dispatch] = useReducer(UpdateTrackTableState, DEFAULT_STATE);

  const [selectedTrackId, setSelectedTrackId] = useState<string | null>(null);

  const filterText = useDebouncedAtomValue(searchAtom, 250);
  useEffect(() => {
    dispatch({ type: UpdateType.FilterChanged, filterText: filterText });
  }, [filterText]);

  const setIconWidths = useCallback(
    (iconWidths: IconWidths) => {
      dispatch({ type: UpdateType.IconWidthsChanged, iconWidths });
    },
    [dispatch]
  );

  useEffect(() => {
    library()
      .getAllPlaylistTracks(selectedPlaylist)
      .then((tracks) => {
        if (tracks) {
          for (const track of tracks || []) {
            PrecomputeTrackSort(track);
          }
          dispatch({ type: UpdateType.TracksChanged, tracks });
          setSelectedTrackId(null);
          if (gridRef.current) {
            gridRef.current.resetAfterIndices({ columnIndex: 0, rowIndex: 0 });
          }
        }
      });
  }, [selectedPlaylist]);

  useDebouncedTypedInput((typedInput: string) => {
    const entry = BinarySearchTypeToShowList(state.typeToShowList, typedInput);
    if (entry && gridRef.current) {
      setSelectedTrackId(state.tracks[entry.trackIndex].id);
      gridRef.current.scrollToItem({
        align: "center",
        rowIndex: entry.displayIndex,
        columnIndex: 0,
      });
    }
  });

  return (
    <TrackTableContext.Provider
      value={{
        sortState: state.sortState,
        columnWidths: state.columnWidths,
        setSortState: (sortState: SortState) => {
          dispatch({
            type: UpdateType.SortChanged,
            sortState: sortState,
          });
        },
      }}
    >
      <AutoSizer>
        {({ height, width }) => (
          <>
            <VariableSizeGrid
              ref={gridRef}
              height={height - 1}
              width={width}
              columnCount={COLUMNS.length}
              columnWidth={(i: number) => state.columnWidths[i]}
              rowCount={state.sortFilteredIndexes.length}
              rowHeight={() => ROW_HEIGHT}
              innerElementType={TrackTableStickyHeaderGrid}
            >
              {(props) => (
                <TrackTableCell
                  {...props}
                  tracks={state.tracks}
                  trackDisplayIndexes={state.sortFilteredIndexes}
                  selectedTrackId={selectedTrackId}
                  setSelectedTrackId={setSelectedTrackId}
                />
              )}
            </VariableSizeGrid>
          </>
        )}
      </AutoSizer>
      <MeasureIconWidths setIconWidths={setIconWidths} />
    </TrackTableContext.Provider>
  );
}

export default TrackTable;
