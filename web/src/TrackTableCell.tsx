import { GridChildComponentProps } from "react-window";
import { Track } from "./Library";
import { COLUMNS } from "./TrackTableColumns";
import { lightestGrey, selectedGrey, white } from "./Colors";
import { CELL_HORIZONTAL_PADDING_SIDE } from "./TrackTableConstants";

function CellBackgroundColor(
  rowIndex: number,
  trackId: string,
  selectedTrackId: string | null
) {
  if (trackId === selectedTrackId) {
    return selectedGrey;
  } else {
    return rowIndex % 2 === 0 ? lightestGrey : white;
  }
}

interface TrackTableCellProps extends GridChildComponentProps {
  tracks: Track[];
  trackDisplayIndexes: number[];
  selectedTrackId: string | null;
  setSelectedTrackId: (trackId: string) => void;
}

export function TrackTableCell(props: TrackTableCellProps) {
  const rowIndex = props.rowIndex;
  const trackId = props.tracks[props.trackDisplayIndexes[rowIndex]].id;
  return (
    <div
      style={{
        backgroundColor: CellBackgroundColor(
          rowIndex,
          trackId,
          props.selectedTrackId
        ),
        padding: `0 ${CELL_HORIZONTAL_PADDING_SIDE}px`,
        boxSizing: "border-box",
        ...props.style,
      }}
      className="valign-center no-select"
      onClick={() => props.setSelectedTrackId(trackId)}
    >
      {COLUMNS[props.columnIndex].render(
        props.tracks[props.trackDisplayIndexes[rowIndex]]
      )}
    </div>
  );
}
