import { useState, useEffect, useRef } from "react";
import { useAtomValue } from "jotai";
import AutoSizer from "react-virtualized-auto-sizer";
import { VariableSizeGrid } from "react-window";
import library, { Track } from "./Library";
import { selectedPlaylistAtom } from "./State";
import { COLUMNS, GetColumnWidths } from "./TrackTableColumns";
import TrackTableHeader from "./TrackTableHeader";
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
  const [tracks, setTracks] = useState<Track[]>([]);
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
        setTracks(tracks || []);
      });
    setSelectedRowIndex(null);
  }, [selectedPlaylist]);

  useEffect(() => {
    setColumnWidths(GetColumnWidths(tracks, iconWidths));
    gridRef.current?.resetAfterIndices({ columnIndex: 0, rowIndex: 0 });
  }, [tracks, iconWidths]);

  return (
    <>
      <TrackTableHeader columnWidths={columnWidths} />
      <AutoSizer>
        {({ height, width }) => (
          <VariableSizeGrid
            ref={gridRef}
            height={height - HEADER_HEIGHT - 1}
            width={width}
            columnCount={COLUMNS.length}
            columnWidth={(i) => columnWidths[i]}
            rowCount={tracks.length}
            rowHeight={(_) => ROW_HEIGHT} // eslint-disable-line @typescript-eslint/no-unused-vars
          >
            {(props) => (
              <TrackTableCell
                {...props}
                tracks={tracks}
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
