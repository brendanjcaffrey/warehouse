import { GridChildComponentProps } from "react-window";
import { Track } from "./Library";
import { COLUMNS } from "./TrackTableColumns";
import { lightestGrey, selectedGrey, white } from "./Colors";
import { CELL_HORIZONTAL_PADDING_SIDE } from "./TrackTableConstants";

function CellBackgroundColor(
  rowIndex: number,
  selectedRowIndex: number | null
) {
  if (rowIndex === selectedRowIndex) {
    return selectedGrey;
  } else {
    return rowIndex % 2 === 0 ? lightestGrey : white;
  }
}

interface TrackTableCellProps extends GridChildComponentProps {
  tracks: Track[];
  selectedRowIndex: number | null;
  setSelectedRowIndex: (rowIndex: number) => void;
}

export function TrackTableCell(props: TrackTableCellProps) {
  return (
    <div
      style={{
        backgroundColor: CellBackgroundColor(
          props.rowIndex,
          props.selectedRowIndex
        ),
        padding: `0 ${CELL_HORIZONTAL_PADDING_SIDE}px`,
        ...props.style,
      }}
      className="valign-center"
      onClick={() => props.setSelectedRowIndex(props.rowIndex)}
    >
      {COLUMNS[props.columnIndex].render(props.tracks[props.rowIndex])}
    </div>
  );
}
