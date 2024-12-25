import { createContext } from "react";
import { SortState } from "./TrackTableSort";

interface TrackTableContextProps {
  sortState: SortState;
  setSortState: (sortState: SortState) => void;
  columnWidths: number[];
}

export const TrackTableContext = createContext<TrackTableContextProps>({
  sortState: { columnId: null, ascending: true },
  setSortState: () => null,
  columnWidths: [],
});
