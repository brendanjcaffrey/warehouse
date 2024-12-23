import { useState, useEffect, useRef } from "react";
import { useAtomValue } from "jotai";
import AutoSizer from "react-virtualized-auto-sizer";
import { VariableSizeGrid } from "react-window";
import { useDebouncedAtomValue } from "./useDebouncedAtomValue";
import library, { Track } from "./Library";
import { SortState, PrecomputeTrackSort } from "./TrackTableSort";
import { FilterTrackList } from "./TrackTableFilter";
import { selectedPlaylistAtom, searchAtom } from "./State";
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
  const [tracks, setTracks] = useState<Track[]>([]);
  const [sortedTrackDisplayIndexes, setSortedTrackDisplayIndexes] = useState<
    number[]
  >([]);
  const [
    sortedFilteredTrackDisplayIndexes,
    setSortedFilteredTrackDisplayIndexes,
  ] = useState<number[]>([]);
  const [iconWidths, setIconWidths] = useState<IconWidths>({
    star: 0,
    arrow: 0,
  });
  const [columnWidths, setColumnWidths] = useState(
    COLUMNS.map(() => DEFAULT_COLUMN_WIDTH)
  );

  const [selectedTrackId, setSelectedTrackId] = useState<string | null>(null);
  const [sortState, setSortState] = useState<SortState>({
    columnId: null,
    ascending: true,
  });
  const searchValue = useDebouncedAtomValue(searchAtom, 250);

  useEffect(() => {
    library()
      .getAllPlaylistTracks(selectedPlaylist)
      .then((tracks) => {
        for (const track of tracks || []) {
          PrecomputeTrackSort(track);
        }
        setTracks(tracks || []);
        setSortedTrackDisplayIndexes([]);
      });
    setSelectedTrackId(null);
  }, [selectedPlaylist]);

  useEffect(() => {
    setColumnWidths(
      GetColumnWidths(tracks, sortedTrackDisplayIndexes, iconWidths)
    );
    gridRef.current?.resetAfterIndices({ columnIndex: 0, rowIndex: 0 });
  }, [tracks, sortedTrackDisplayIndexes, iconWidths]);

  useEffect(() => {
    const allIndexes = tracks.map((_, i) => i);
    if (sortState.columnId === null) {
      setSortedTrackDisplayIndexes(allIndexes);
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
      setSortedTrackDisplayIndexes(sortedIndexes);
    }
  }, [tracks, sortState]);

  useEffect(() => {
    if (searchValue === "") {
      setSortedFilteredTrackDisplayIndexes(sortedTrackDisplayIndexes);
    } else {
      setSortedFilteredTrackDisplayIndexes(
        FilterTrackList(tracks, sortedTrackDisplayIndexes, searchValue)
      );
    }
  }, [sortedTrackDisplayIndexes, searchValue, tracks]);

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
            rowCount={sortedFilteredTrackDisplayIndexes.length}
            rowHeight={(_) => ROW_HEIGHT} // eslint-disable-line @typescript-eslint/no-unused-vars
          >
            {(props) => (
              <TrackTableCell
                {...props}
                tracks={tracks}
                trackDisplayIndexes={sortedFilteredTrackDisplayIndexes}
                selectedTrackId={selectedTrackId}
                setSelectedTrackId={setSelectedTrackId}
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
