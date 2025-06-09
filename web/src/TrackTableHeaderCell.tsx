import { CSSProperties } from "react";
import { useTheme } from "@mui/material";
import { ArrowDownwardRounded, ArrowUpwardRounded } from "@mui/icons-material";
import { Column, DisplayedTrackKeys } from "./TrackTableColumns";
import { SortState } from "./TrackTableSort";
import { CELL_HORIZONTAL_PADDING_SIDE } from "./TrackTableConstants";

interface SortIconProps {
  sortState: SortState;
  columnId: keyof DisplayedTrackKeys;
}

function SortIcon({ sortState, columnId }: SortIconProps): JSX.Element {
  if (sortState.columnId === columnId) {
    if (sortState.ascending) {
      return <ArrowUpwardRounded fontSize="small" color="primary" />;
    } else {
      return <ArrowDownwardRounded fontSize="small" color="primary" />;
    }
  } else {
    return (
      <ArrowUpwardRounded
        fontSize="small"
        className="hover-only"
        color="action"
      />
    );
  }
}

interface TrackTableHeaderCellProps {
  column: Column;
  sortState: SortState;
  setSortState: (sortState: SortState) => void;
  style: CSSProperties;
}

export function TrackTableHeaderCell({
  column,
  sortState,
  setSortState,
  style,
}: TrackTableHeaderCellProps) {
  const theme = useTheme();

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
        borderBottom: `1px solid`,
        fontWeight: "bold",
        cursor: "pointer",
        color: theme.palette.text.secondary,
        backgroundColor: theme.palette.background.default,
        ...style,
      }}
      className="has-sort-icon valign-center no-select"
      onClick={() => updateSortState()}
    >
      {column.label}
      <SortIcon sortState={sortState} columnId={column.id} />
    </div>
  );
}
