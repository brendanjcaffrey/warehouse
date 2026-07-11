import { Track } from "./Library";
import { TrackColumn } from "./TrackColumns";

// filtering needs a column's id, type and comparable value plus, for text
// columns, the display text people actually type against
type FilterColumn = Pick<TrackColumn, "id" | "type" | "value" | "text">;

// a raw string per column, straight from the filter inputs; blank means the
// column isn't filtered
export type FilterState = Record<string, string>;

// reads a plain number or an m:ss duration so the time column can be filtered
// the way it reads, e.g. "3:30"
function parseNumberToken(token: string): number | null {
  const trimmed = token.trim();
  if (/^\d+:\d{1,2}$/.test(trimmed)) {
    const [minutes, seconds] = trimmed.split(":");
    return Number(minutes) * 60 + Number(seconds);
  }
  if (/^\d+(\.\d+)?$/.test(trimmed)) {
    return Number(trimmed);
  }
  return null;
}

// turns a number-column filter string into a predicate: a comparison like
// ">=2000", a range like "1990-2000", or a bare value for an exact match.
// returns null when the string is blank or not understood, so a half-typed
// filter leaves the column unfiltered rather than blanking the list
export function compileNumberFilter(
  input: string
): ((value: number) => boolean) | null {
  const trimmed = input.trim();
  if (trimmed === "") {
    return null;
  }

  const operator = trimmed.match(/^(>=|<=|>|<|=)\s*(.+)$/);
  if (operator) {
    const bound = parseNumberToken(operator[2]);
    if (bound === null) {
      return null;
    }
    switch (operator[1]) {
      case ">":
        return (value) => value > bound;
      case ">=":
        return (value) => value >= bound;
      case "<":
        return (value) => value < bound;
      case "<=":
        return (value) => value <= bound;
      default:
        return (value) => value === bound;
    }
  }

  const range = trimmed.match(/^(.+?)\s*-\s*(.+)$/);
  if (range) {
    const low = parseNumberToken(range[1]);
    const high = parseNumberToken(range[2]);
    if (low === null || high === null) {
      return null;
    }
    return (value) => value >= low && value <= high;
  }

  const exact = parseNumberToken(trimmed);
  if (exact === null) {
    return null;
  }
  return (value) => value === exact;
}

// keeps the tracks that match every active column filter. text columns match a
// case-insensitive substring of their display text; number columns compile to a
// comparison. an all-blank state returns the tracks untouched
export function filterTracks(
  tracks: Track[],
  filters: FilterState,
  columns: FilterColumn[]
): Track[] {
  const byId = new Map(columns.map((column) => [column.id, column]));
  const predicates: Array<(track: Track) => boolean> = [];

  for (const [columnId, raw] of Object.entries(filters)) {
    const column = byId.get(columnId);
    const query = raw.trim();
    if (!column || query === "") {
      continue;
    }

    if (column.type === "text") {
      const needle = query.toLowerCase();
      const text = column.text ?? ((track) => String(column.value(track)));
      predicates.push((track) => text(track).toLowerCase().includes(needle));
    } else {
      const test = compileNumberFilter(query);
      if (test) {
        predicates.push((track) => test(Number(column.value(track))));
      }
    }
  }

  if (predicates.length === 0) {
    return tracks;
  }
  return tracks.filter((track) => predicates.every((test) => test(track)));
}

// keeps the tracks whose name, artist, album or genre contains the term, matched
// case-insensitively like the per-column text filters but spanning every text
// column at once. this backs the nav search box, so one box narrows the grid
// across all the text fields. a blank term returns the tracks untouched
export function searchTracks(
  tracks: Track[],
  query: string,
  columns: FilterColumn[]
): Track[] {
  const needle = query.trim().toLowerCase();
  if (needle === "") {
    return tracks;
  }
  const texts = columns
    .filter((column) => column.type === "text")
    .map(
      (column) => column.text ?? ((track: Track) => String(column.value(track)))
    );
  return tracks.filter((track) =>
    texts.some((text) => text(track).toLowerCase().includes(needle))
  );
}

// whether any column filter would actually narrow the list
export function hasActiveFilters(filters: FilterState): boolean {
  return Object.values(filters).some((value) => value.trim() !== "");
}
