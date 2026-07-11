import { TRACK_COLUMNS, TrackColumn } from "./TrackColumns";

// the column controls only need a column's id and default width; the rest of the
// column (render, value, ...) stays out of the layout so this stays testable
export type LayoutColumn = Pick<TrackColumn, "id" | "width">;

// the user's column arrangement, persisted across sessions: the display order,
// the ids they've hidden, and any widths they've dragged to a fixed px. a column
// missing from widths keeps its default flexible sizing
export interface ColumnLayout {
  order: string[];
  hidden: string[];
  widths: Record<string, number>;
}

// columns never shrink below this when dragged, so a column can't be lost
export const COLUMN_MIN_WIDTH = 48;

// the untouched layout: every column visible, in its defined order, at its
// default width
export function defaultTrackLayout(
  columns: LayoutColumn[] = TRACK_COLUMNS
): ColumnLayout {
  return { order: columns.map((column) => column.id), hidden: [], widths: {} };
}

// folds a saved layout onto the current column set: drops ids that no longer
// exist, appends columns added since it was saved, and clears widths for gone
// columns. this keeps an old persisted layout working when the column set changes
export function reconcileLayout(
  layout: ColumnLayout,
  columns: LayoutColumn[]
): ColumnLayout {
  const ids = columns.map((column) => column.id);
  const known = new Set(ids);

  const order = layout.order.filter((id) => known.has(id));
  for (const id of ids) {
    if (!order.includes(id)) {
      order.push(id);
    }
  }

  const hidden = layout.hidden.filter((id) => known.has(id));

  const widths: Record<string, number> = {};
  for (const id of ids) {
    if (typeof layout.widths[id] === "number") {
      widths[id] = layout.widths[id];
    }
  }

  return { order, hidden, widths };
}

// the columns to actually draw, in display order with hidden ones removed
export function visibleColumns<T extends { id: string }>(
  layout: ColumnLayout,
  columns: T[]
): T[] {
  const byId = new Map(columns.map((column) => [column.id, column]));
  const hidden = new Set(layout.hidden);
  const result: T[] = [];
  for (const id of layout.order) {
    if (hidden.has(id)) {
      continue;
    }
    const column = byId.get(id);
    if (column) {
      result.push(column);
    }
  }
  return result;
}

// a dragged column becomes a fixed px width; an untouched one keeps its default
// grid track sizing so it still flexes with the viewport
export function resolveColumnWidth(
  column: LayoutColumn,
  layout: ColumnLayout
): string {
  const override = layout.widths[column.id];
  return typeof override === "number" ? `${override}px` : column.width;
}

// the shared grid template the header and body rows both use, so their columns
// line up
export function buildTemplate(
  columns: LayoutColumn[],
  layout: ColumnLayout
): string {
  return columns.map((column) => resolveColumnWidth(column, layout)).join(" ");
}

// moves a column so it lands directly before the target; a null target sends it
// to the end. reordering keeps hidden columns in place around it
export function moveColumn(
  layout: ColumnLayout,
  draggedId: string,
  targetId: string | null
): ColumnLayout {
  if (draggedId === targetId) {
    return layout;
  }
  const order = layout.order.filter((id) => id !== draggedId);
  const index = targetId === null ? order.length : order.indexOf(targetId);
  order.splice(index === -1 ? order.length : index, 0, draggedId);
  return { ...layout, order };
}

// pins a width to whole pixels and never below the minimum
export function clampColumnWidth(width: number): number {
  return Math.max(COLUMN_MIN_WIDTH, Math.round(width));
}

export function setColumnWidth(
  layout: ColumnLayout,
  columnId: string,
  width: number
): ColumnLayout {
  return {
    ...layout,
    widths: { ...layout.widths, [columnId]: clampColumnWidth(width) },
  };
}

// drops every dragged width so the columns return to their default flexible
// sizing, leaving the order and hidden columns as they were
export function resetColumnWidths(layout: ColumnLayout): ColumnLayout {
  return { ...layout, widths: {} };
}

// shows a hidden column or hides a visible one, but refuses to hide the last
// visible column so the grid can never end up with nothing to show
export function toggleColumnHidden(
  layout: ColumnLayout,
  columnId: string,
  columns: LayoutColumn[]
): ColumnLayout {
  if (layout.hidden.includes(columnId)) {
    return {
      ...layout,
      hidden: layout.hidden.filter((id) => id !== columnId),
    };
  }
  if (visibleColumns(layout, columns).length <= 1) {
    return layout;
  }
  return { ...layout, hidden: [...layout.hidden, columnId] };
}

// validates an unknown value parsed from storage into a well-formed layout,
// keeping only string ids and finite widths; anything off falls back to a default
export function normalizeTrackLayout(raw: unknown): ColumnLayout {
  const base = defaultTrackLayout();
  if (!raw || typeof raw !== "object") {
    return base;
  }
  const value = raw as Partial<ColumnLayout>;

  const order = Array.isArray(value.order)
    ? value.order.filter((id): id is string => typeof id === "string")
    : base.order;

  const hidden = Array.isArray(value.hidden)
    ? value.hidden.filter((id): id is string => typeof id === "string")
    : [];

  const widths: Record<string, number> = {};
  if (value.widths && typeof value.widths === "object") {
    for (const [id, width] of Object.entries(value.widths)) {
      if (typeof width === "number" && Number.isFinite(width)) {
        widths[id] = width;
      }
    }
  }

  return reconcileLayout({ order, hidden, widths }, TRACK_COLUMNS);
}
