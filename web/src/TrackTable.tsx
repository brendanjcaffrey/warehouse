import { useState, useEffect, useRef, useReducer, useCallback } from "react";
import { useAtomValue } from "jotai";
import AutoSizer from "react-virtualized-auto-sizer";
import { VariableSizeGrid } from "react-window";
import { useDebouncedAtomValue } from "./useDebouncedAtomValue";
import { useDebouncedTypedInput } from "./useDebouncedTypedInput";
import library from "./Library";
import { player } from "./Player";
import {
  selectedPlaylistIdAtom,
  searchAtom,
  stoppedAtom,
  playingTrackAtom,
} from "./State";
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
import { TrackContextMenu, TrackContextMenuData } from "./TrackContextMenu";
import { TrackAction } from "./TrackAction";
import { ROW_HEIGHT } from "./TrackTableConstants";

function TrackTable() {
  const gridRef = useRef<VariableSizeGrid>(null);

  const selectedPlaylistId = useAtomValue(selectedPlaylistIdAtom);
  const stopped = useAtomValue(stoppedAtom);
  const playingTrack = useAtomValue(playingTrackAtom);
  const [state, dispatch] = useReducer(UpdateTrackTableState, DEFAULT_STATE);

  const [selectedTrackId, setSelectedTrackId] = useState<string | null>(null);
  const [contextMenuData, setContextMenuData] =
    useState<TrackContextMenuData | null>(null);

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
      .getAllPlaylistTracks(selectedPlaylistId)
      .then((tracks) => {
        if (tracks) {
          for (const track of tracks || []) {
            PrecomputeTrackSort(track);
          }
          dispatch({
            type: UpdateType.TracksChanged,
            playlistId: selectedPlaylistId,
            tracks,
          });
          setSelectedTrackId(null);
          if (gridRef.current) {
            gridRef.current.resetAfterIndices({ columnIndex: 0, rowIndex: 0 });
          }
        }
      });
  }, [selectedPlaylistId]);

  useEffect(() => {
    player().setDisplayedTrackIds(
      state.playlistId,
      state.sortFilteredIndexes.map((idx) => state.tracks[idx].id)
    );
  }, [state]);

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

  const showContextMenu = useCallback(
    (event: React.MouseEvent, trackId: string) => {
      event.preventDefault();
      setSelectedTrackId(trackId);
      setContextMenuData({
        trackId: trackId,
        mouseX: event.clientX,
        mouseY: event.clientY,
      });
    },
    [setContextMenuData]
  );

  const handleTrackAction = useCallback(
    (action: TrackAction, trackId: string | undefined) => {
      if (!trackId) {
        return;
      }
      switch (action) {
        case TrackAction.PLAY:
          player().playTrack(trackId);
          break;
        case TrackAction.PLAY_NEXT:
          player().playTrackNext(trackId);
          break;
        case TrackAction.DOWNLOAD:
          player().downloadTrack(trackId);
          break;
        case TrackAction.EDIT:
          // TODO
          break;
      }
      setContextMenuData(null);
    },
    [setContextMenuData]
  );

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
                  playingTrackId={
                    !stopped && playingTrack ? playingTrack.id : null
                  }
                  showContextMenu={showContextMenu}
                  handleAction={handleTrackAction}
                />
              )}
            </VariableSizeGrid>
          </>
        )}
      </AutoSizer>
      <MeasureIconWidths setIconWidths={setIconWidths} />
      <TrackContextMenu
        data={contextMenuData}
        setData={setContextMenuData}
        handleAction={handleTrackAction}
      />
    </TrackTableContext.Provider>
  );
}

export default TrackTable;
