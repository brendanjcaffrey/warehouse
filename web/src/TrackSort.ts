import { Track } from "./Library";
import { TrackColumn } from "./TrackColumns";

export type SortDirection = "asc" | "desc";

export interface SortKey {
  columnId: string;
  direction: SortDirection;
}

// sorting only needs a column's id, type and comparable value, so tests can pass
// lightweight stand-ins instead of the full render-carrying columns
type SortColumn = Pick<TrackColumn, "id" | "type" | "value">;

// advances the sort state for a clicked header. a plain click sorts by that
// column alone, cycling asc -> desc -> unsorted; a shift click (additive) keeps
// the other keys and cycles just this one, dropping it on the third click. this
// is the multi-column behaviour people expect from a spreadsheet grid
export function cycleSort(
  sortKeys: SortKey[],
  columnId: string,
  additive: boolean
): SortKey[] {
  const existing = sortKeys.find((key) => key.columnId === columnId);

  if (!additive) {
    if (!existing || sortKeys.length > 1) {
      return [{ columnId, direction: "asc" }];
    }
    if (existing.direction === "asc") {
      return [{ columnId, direction: "desc" }];
    }
    return [];
  }

  if (!existing) {
    return [...sortKeys, { columnId, direction: "asc" }];
  }
  if (existing.direction === "asc") {
    return sortKeys.map((key) =>
      key.columnId === columnId ? { columnId, direction: "desc" } : key
    );
  }
  return sortKeys.filter((key) => key.columnId !== columnId);
}

// returns a new array sorted by the keys in priority order; an empty spec leaves
// the tracks in their original order. the sort is stable, so ties fall through to
// the next key and finally to the incoming order
export function sortTracks(
  tracks: Track[],
  sortKeys: SortKey[],
  columns: SortColumn[]
): Track[] {
  if (sortKeys.length === 0) {
    return tracks;
  }

  const byId = new Map(columns.map((column) => [column.id, column]));

  return [...tracks].sort((a, b) => {
    for (const key of sortKeys) {
      const column = byId.get(key.columnId);
      if (!column) {
        continue;
      }
      const aValue = column.value(a);
      const bValue = column.value(b);
      let comparison: number;
      if (column.type === "number") {
        comparison = (aValue as number) - (bValue as number);
      } else {
        comparison = String(aValue).localeCompare(String(bValue));
      }
      if (comparison !== 0) {
        return key.direction === "asc" ? comparison : -comparison;
      }
    }
    return 0;
  });
}
