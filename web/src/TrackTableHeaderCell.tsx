import { CSSProperties } from "react";
import { ArrowDownwardRounded, ArrowUpwardRounded } from "@mui/icons-material";
import { Column, DisplayedTrackKeys } from "./TrackTableColumns";
import { SortState } from "./TrackTableSort";
import { lighterGrey, titleGrey, white } from "./Colors";
import { CELL_HORIZONTAL_PADDING_SIDE } from "./TrackTableConstants";

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

interface TrackTableHeaderCellProps {
  column: Column;
  sortState: SortState;
  setSortState: (sortState: SortState) => void;
  style: CSSProperties;
  label: string;
}

export function TrackTableHeaderCell({
  column,
  sortState,
  setSortState,
  style,
  label,
}: TrackTableHeaderCellProps) {
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
        padding: `0 ${CELL_HORIZONTAL_PADDING_SIDE}px`,
        boxSizing: "border-box",
        borderBottom: `1px solid ${titleGrey}`,
        fontWeight: "bold",
        cursor: "pointer",
        color: titleGrey,
        backgroundColor: white,
        ...style,
      }}
      className="has-sort-icon valign-center no-select"
      onClick={() => updateSortState()}
    >
      {label}
      <SortIcon sortState={sortState} columnId={column.id} />
    </div>
  );
}
