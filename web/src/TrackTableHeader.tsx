import { ArrowDownwardRounded, ArrowUpwardRounded } from "@mui/icons-material";
import { COLUMNS, Column, DisplayedTrackKeys } from "./TrackTableColumns";
import { SortState } from "./TrackTableSort";
import { lighterGrey, titleGrey } from "./Colors";
import {
  HEADER_HEIGHT,
  CELL_HORIZONTAL_PADDING_SIDE,
} from "./TrackTableConstants";

interface SortIconProps {
  sortState: SortState;
  columnId: keyof DisplayedTrackKeys;
}

function SortIcon({ sortState, columnId }: SortIconProps): JSX.Element {
  if (sortState.columnId === columnId) {
    if (sortState.ascending) {
      return (
        <ArrowUpwardRounded fontSize="small" style={{ color: titleGrey }} />
      );
    } else {
      return (
        <ArrowDownwardRounded fontSize="small" style={{ color: titleGrey }} />
      );
    }
  } else {
    return (
      <ArrowUpwardRounded
        fontSize="small"
        className="hover-only"
        style={{ color: lighterGrey }}
      />
    );
  }
}

interface HeaderCellProps {
  column: Column;
  columnWidth: number;
  columnLeft: number;
  sortState: SortState;
  setSortState: (sortState: SortState) => void;
}

function HeaderCell({
  column,
  columnWidth,
  columnLeft,
  sortState,
  setSortState,
}: HeaderCellProps) {
  const updateSortState = () => {
    if (sortState.columnId === column.id) {
      if (sortState.ascending) {
        setSortState({ columnId: column.id, ascending: false });
      } else {
        setSortState({ columnId: null, ascending: false });
      }
    } else {
      setSortState({ columnId: column.id, ascending: true });
    }
  };

  return (
    <div
      style={{
        position: "absolute",
        top: 0,
        left: columnLeft,
        width: columnWidth,
        height: HEADER_HEIGHT,
        padding: `0 ${CELL_HORIZONTAL_PADDING_SIDE}px`,
        boxSizing: "border-box",
        borderBottom: `1px solid ${titleGrey}`,
        fontWeight: "bold",
        cursor: "pointer",
        color: titleGrey,
      }}
      className="has-sort-icon valign-center"
      onClick={() => updateSortState()}
    >
      {column.label}
      <SortIcon sortState={sortState} columnId={column.id} />
    </div>
  );
}

export interface TrackTableHeaderProps {
  columnWidths: number[];
  sortState: SortState;
  setSortState: (sortState: SortState) => void;
}

export function TrackTableHeader({
  columnWidths,
  sortState,
  setSortState,
}: TrackTableHeaderProps) {
  let cumSum = 0;
  const cellLefts = columnWidths.map((width) => {
    const result = cumSum;
    cumSum += width;
    return result;
  });

  return (
    <div style={{ overflow: "visible", height: HEADER_HEIGHT, width: 0 }}>
      <div
        style={{
          position: "relative",
          height: 0,
          width: 0,
        }}
      >
        {COLUMNS.map((column, index) => (
          <HeaderCell
            key={column.id}
            column={column}
            columnWidth={columnWidths[index]}
            columnLeft={cellLefts[index]}
            sortState={sortState}
            setSortState={setSortState}
          />
        ))}
      </div>
    </div>
  );
}
