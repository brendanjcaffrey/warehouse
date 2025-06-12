import { useState, useEffect, useRef, useReducer, useCallback } from "react";
import { useAtom, useAtomValue, useSetAtom } from "jotai";
import AutoSizer from "react-virtualized-auto-sizer";
import { VariableSizeGrid } from "react-window";
import EditTrackPanel from "./EditTrackPanel";
import { useDebouncedAtomValue } from "./useDebouncedAtomValue";
import { useDebouncedTypeToShowInput } from "./useDebouncedTypeToShowInput";
import library, { Track } from "./Library";
import { player } from "./Player";
import {
  trackUpdatedFnAtom,
  showTrackFnAtom,
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
import { PlaylistTrack, PlaylistEntry } from "./Types";

function showTrackInGrid(
  gridRef: React.RefObject<VariableSizeGrid>,
  displayedRows: React.RefObject<[number, number]>,
  sortedFilteredPlaylistOffsets: number[],
  playlistOffset: number
) {
  const row = sortedFilteredPlaylistOffsets.indexOf(playlistOffset);
  if (row !== -1 && gridRef.current) {
    // if the track is already displayed, don't scroll
    if (
      displayedRows.current &&
      // the row #s seem to be off slightly? just move the range in by 1 on each side
      displayedRows.current[0] + 1 <= row &&
      displayedRows.current[1] - 1 >= row
    ) {
      return;
    }
    gridRef.current.scrollToItem({
      align: "center",
      rowIndex: row,
      columnIndex: 0,
    });
  }
}

function TrackTable() {
  const gridRef = useRef<VariableSizeGrid>(null);

  const setTrackUpdatedFn = useSetAtom(trackUpdatedFnAtom);
  const setShowTrackFn = useSetAtom(showTrackFnAtom);
  const [selectedPlaylistId, setSelectedPlaylistId] = useAtom(
    selectedPlaylistIdAtom
  );
  const stopped = useAtomValue(stoppedAtom);
  const playingTrack = useAtomValue(playingTrackAtom);
  const [state, dispatch] = useReducer(UpdateTrackTableState, DEFAULT_STATE);
  const offsetToShowAfterPlaylistSwitch = useRef<number | undefined>(undefined);
  const displayedRowIdxs = useRef<[number, number]>([-1, -1]);

  const [contextMenuData, setContextMenuData] =
    useState<TrackContextMenuData | null>(null);

  const [editFormOpen, setEditFormOpen] = useState(false);
  const [editFormTrack, setEditFormTrack] = useState<Track | undefined>(
    undefined
  );

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

  const setSelectedPlaylistOffset = useCallback(
    (playlistOffset: number) => {
      dispatch({
        type: UpdateType.SelectedPlaylistOffsetChanged,
        playlistOffset,
      });
    },
    [dispatch]
  );

  const closeEditTrackPanel = useCallback(() => {
    setEditFormOpen(false);
  }, [setEditFormOpen]);

  useEffect(() => {
    library()
      .getAllPlaylistTracks(selectedPlaylistId)
      .then((tracks) => {
        if (tracks) {
          for (const track of tracks || []) {
            PrecomputeTrackSort(track);
          }
          let newSelectedOffset = undefined;
          if (playingTrack?.playlistId === selectedPlaylistId) {
            newSelectedOffset = playingTrack?.playlistOffset;
          }
          dispatch({
            type: UpdateType.TracksChanged,
            playlistId: selectedPlaylistId,
            tracks,
            selectedPlaylistOffset: newSelectedOffset,
          });
          // have to reset the column widths
          if (gridRef.current) {
            gridRef.current.resetAfterIndices({ columnIndex: 0, rowIndex: 0 });
          }
          offsetToShowAfterPlaylistSwitch.current = newSelectedOffset;
        }
      });
  }, [selectedPlaylistId]);

  useEffect(() => {
    player().setDisplayedTrackIds(
      state.playlistId,
      state.sortedFilteredPlaylistOffsets.map((playlistOffset) => {
        return {
          trackId: state.tracks[playlistOffset].id,
          playlistOffset,
        };
      })
    );

    const playlistOffset = offsetToShowAfterPlaylistSwitch.current;
    if (playlistOffset) {
      offsetToShowAfterPlaylistSwitch.current = undefined;
      setSelectedPlaylistOffset(playlistOffset);
      showTrackInGrid(
        gridRef,
        displayedRowIdxs,
        state.sortedFilteredPlaylistOffsets,
        playlistOffset
      );
    }
  }, [state]);

  const trackUpdated = useCallback((track: Track) => {
    dispatch({ type: UpdateType.TrackUpdated, track });
  }, []);

  useEffect(() => {
    setTrackUpdatedFn({ fn: trackUpdated });
  }, [setTrackUpdatedFn, trackUpdated]);

  // because the update tracks effect is async, if we want to change the playlist and show a track,
  // we need to wait for the async effect to finish before showing the track. there's no clean way
  // to do this really, so we just use a ref to store the track id to show after the async effect
  const showTrack = useCallback(
    (entry: PlaylistEntry) => {
      if (state.playlistId !== entry.playlistId) {
        offsetToShowAfterPlaylistSwitch.current = entry.playlistOffset;
        setSelectedPlaylistId(entry.playlistId);
        return;
      }
      setSelectedPlaylistOffset(entry.playlistOffset);
      showTrackInGrid(
        gridRef,
        displayedRowIdxs,
        state.sortedFilteredPlaylistOffsets,
        entry.playlistOffset
      );
    },
    [state, setSelectedPlaylistId, setSelectedPlaylistOffset]
  );

  useEffect(() => {
    setShowTrackFn({ fn: showTrack });
  }, [setShowTrackFn, showTrack]);

  useDebouncedTypeToShowInput((typedInput: string) => {
    const entry = BinarySearchTypeToShowList(state.typeToShowList, typedInput);
    if (entry && gridRef.current) {
      setSelectedPlaylistOffset(entry.trackIndex);
      gridRef.current.scrollToItem({
        align: "center",
        rowIndex: entry.displayIndex,
        columnIndex: 0,
      });
    }
  });

  const showContextMenu = useCallback(
    (event: React.MouseEvent, playlistTrack: PlaylistTrack) => {
      event.preventDefault();
      setSelectedPlaylistOffset(playlistTrack.playlistOffset);
      setContextMenuData({
        playlistTrack,
        mouseX: event.clientX,
        mouseY: event.clientY,
      });
    },
    [setContextMenuData]
  );

  const handleTrackAction = useCallback(
    (action: TrackAction, playlistTrack: PlaylistTrack) => {
      switch (action) {
        case TrackAction.PLAY:
          player().playTrack({
            trackId: playlistTrack.trackId,
            playlistOffset: playlistTrack.playlistOffset,
          });
          break;
        case TrackAction.PLAY_NEXT:
          player().playTrackNext(playlistTrack);
          break;
        case TrackAction.DOWNLOAD:
          player().downloadMusic(playlistTrack.trackId);
          break;
        case TrackAction.EDIT:
          library()
            .getTrack(playlistTrack.trackId)
            .then((track) => {
              if (track) {
                setEditFormOpen(true);
                setEditFormTrack(track);
              }
            });
          break;
      }
      setContextMenuData(null);
    },
    [setContextMenuData]
  );

  const handleArrowKeyMovement = useCallback(
    (event: KeyboardEvent) => {
      if (event.target instanceof HTMLInputElement) {
        return;
      }

      var adjustment: number | undefined = undefined;
      if (event.key === "ArrowUp") {
        adjustment = -1;
      } else if (event.key === "ArrowDown") {
        adjustment = 1;
      }

      if (adjustment) {
        if (state.selectedPlaylistEntry) {
          let index = state.sortedFilteredPlaylistOffsets.findIndex(
            (o) => o === state.selectedPlaylistEntry!.playlistOffset
          );
          if (index === -1) {
            return;
          }

          let newIndex = index + adjustment;
          newIndex = Math.max(newIndex, 0);
          newIndex = Math.min(
            newIndex,
            state.sortedFilteredPlaylistOffsets.length - 1
          );
          dispatch({
            type: UpdateType.SelectedPlaylistOffsetChanged,
            playlistOffset: state.sortedFilteredPlaylistOffsets[newIndex],
          });
          showTrackInGrid(
            gridRef,
            displayedRowIdxs,
            state.sortedFilteredPlaylistOffsets,
            state.sortedFilteredPlaylistOffsets[newIndex]
          );
          event.preventDefault();
        }
      }
    },
    [state, dispatch]
  );

  useEffect(() => {
    document.addEventListener("keydown", handleArrowKeyMovement);
    return () => {
      document.removeEventListener("keydown", handleArrowKeyMovement);
    };
  }, [handleArrowKeyMovement]);

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
              rowCount={state.sortedFilteredPlaylistOffsets.length}
              rowHeight={() => ROW_HEIGHT}
              innerElementType={TrackTableStickyHeaderGrid}
              onItemsRendered={({
                visibleRowStartIndex,
                visibleRowStopIndex,
              }) => {
                displayedRowIdxs.current = [
                  visibleRowStartIndex,
                  visibleRowStopIndex,
                ];
              }}
            >
              {(props) => (
                <TrackTableCell
                  {...props}
                  playlistId={state.playlistId}
                  tracks={state.tracks}
                  trackDisplayIndexes={state.sortedFilteredPlaylistOffsets}
                  selectedPlaylistEntry={state.selectedPlaylistEntry}
                  setSelectedPlaylistOffset={setSelectedPlaylistOffset}
                  playingPlaylistEntry={
                    !stopped && playingTrack
                      ? {
                          playlistId: playingTrack.playlistId,
                          playlistOffset: playingTrack.playlistOffset,
                        }
                      : undefined
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
      <EditTrackPanel
        open={editFormOpen}
        track={editFormTrack}
        setTrack={setEditFormTrack}
        closeEditTrackPanel={closeEditTrackPanel}
      />
    </TrackTableContext.Provider>
  );
}

export default TrackTable;
