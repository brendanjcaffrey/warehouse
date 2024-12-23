import { useState, useEffect, useRef } from "react";
import { useAtomValue } from "jotai";
import AutoSizer from "react-virtualized-auto-sizer";
import { VariableSizeGrid } from "react-window";
import library, { Track } from "./Library";
import { SortState, PrecomputeTrackSort } from "./TrackTableSort";
import { selectedPlaylistAtom } from "./State";
import { COLUMNS, GetColumnWidths } from "./TrackTableColumns";
import { TrackTableHeader } from "./TrackTableHeader";
import { TrackTableCell } from "./TrackTableCell";
import { IconWidths, MeasureIconWidths } from "./MeasureIconWidths";
import {
  ROW_HEIGHT,
  HEADER_HEIGHT,
  DEFAULT_COLUMN_WIDTH,
} from "./TrackTableConstants";

function TrackTable() {
  const gridRef = useRef<VariableSizeGrid>(null);

  const selectedPlaylist = useAtomValue(selectedPlaylistAtom);
  const [selectedRowIndex, setSelectedRowIndex] = useState<number | null>(null);
  const [sortState, setSortState] = useState<SortState>({
    columnId: null,
    ascending: true,
  });
  const [tracks, setTracks] = useState<Track[]>([]);
  const [trackDisplayIndexes, setTrackDisplayIndexes] = useState<number[]>([]);
  const [iconWidths, setIconWidths] = useState<IconWidths>({
    star: 0,
    arrow: 0,
  });
  const [columnWidths, setColumnWidths] = useState(
    COLUMNS.map(() => DEFAULT_COLUMN_WIDTH)
  );

  useEffect(() => {
    library()
      .getAllPlaylistTracks(selectedPlaylist)
      .then((tracks) => {
        for (const track of tracks || []) {
          PrecomputeTrackSort(track);
        }
        setTracks(tracks || []);
        setTrackDisplayIndexes([]);
      });
    setSelectedRowIndex(null);
  }, [selectedPlaylist]);

  useEffect(() => {
    const allIndexes = tracks.map((_, i) => i);
    if (sortState.columnId === null) {
      setTrackDisplayIndexes(allIndexes);
    } else {
      const column = COLUMNS.find((column) => column.id === sortState.columnId);
      if (!column) {
        console.error(`Invalid column id: ${sortState.columnId}`);
        return;
      }
      const sortedIndexes = allIndexes.sort((a, b) => {
        const trackA = tracks[a];
        const trackB = tracks[b];
        for (const key of column.sortKeys) {
          const valueA = trackA[key];
          const valueB = trackB[key];
          if (valueA !== valueB) {
            return valueA < valueB ? -1 : 1;
          }
        }
        return 0;
      });
      if (!sortState.ascending) {
        sortedIndexes.reverse();
      }
      setTrackDisplayIndexes(sortedIndexes);
    }
  }, [tracks, sortState]);

  useEffect(() => {
    setColumnWidths(GetColumnWidths(tracks, trackDisplayIndexes, iconWidths));
    gridRef.current?.resetAfterIndices({ columnIndex: 0, rowIndex: 0 });
  }, [tracks, trackDisplayIndexes, iconWidths]);

  return (
    <>
      <TrackTableHeader
        columnWidths={columnWidths}
        sortState={sortState}
        setSortState={setSortState}
      />
      <AutoSizer>
        {({ height, width }) => (
          <VariableSizeGrid
            ref={gridRef}
            height={height - HEADER_HEIGHT - 1}
            width={width}
            columnCount={COLUMNS.length}
            columnWidth={(i) => columnWidths[i]}
            rowCount={trackDisplayIndexes.length}
            rowHeight={(_) => ROW_HEIGHT} // eslint-disable-line @typescript-eslint/no-unused-vars
          >
            {(props) => (
              <TrackTableCell
                {...props}
                tracks={tracks}
                trackDisplayIndexes={trackDisplayIndexes}
                selectedRowIndex={selectedRowIndex}
                setSelectedRowIndex={setSelectedRowIndex}
              />
            )}
          </VariableSizeGrid>
        )}
      </AutoSizer>
      <MeasureIconWidths setIconWidths={setIconWidths} />
    </>
  );
}

export default TrackTable;
