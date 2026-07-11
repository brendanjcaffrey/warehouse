import { expect, test } from "vitest";
import {
  buildTemplate,
  clampColumnWidth,
  COLUMN_MIN_WIDTH,
  defaultTrackLayout,
  moveColumn,
  normalizeTrackLayout,
  reconcileLayout,
  resetColumnWidths,
  resolveColumnWidth,
  setColumnWidth,
  toggleColumnHidden,
  visibleColumns,
} from "../src/TrackLayout";

const columns = [
  { id: "name", width: "minmax(180px, 2fr)" },
  { id: "artist", width: "minmax(140px, 1.5fr)" },
  { id: "year", width: "72px" },
];

function layoutOf(order: string[], hidden: string[] = [], widths = {}) {
  return { order, hidden, widths };
}

test("default layout lists every column, visible, at default width", () => {
  const layout = defaultTrackLayout(columns);
  expect(layout.order).toEqual(["name", "artist", "year"]);
  expect(layout.hidden).toEqual([]);
  expect(layout.widths).toEqual({});
});

test("reconcile drops unknown ids and appends new columns", () => {
  const saved = layoutOf(["year", "gone", "name"], ["gone", "artist"], {
    year: 90,
    gone: 50,
  });
  const reconciled = reconcileLayout(saved, columns);
  expect(reconciled.order).toEqual(["year", "name", "artist"]);
  expect(reconciled.hidden).toEqual(["artist"]);
  expect(reconciled.widths).toEqual({ year: 90 });
});

test("visible columns follow the order and skip hidden ones", () => {
  const layout = layoutOf(["year", "name", "artist"], ["name"]);
  expect(visibleColumns(layout, columns).map((c) => c.id)).toEqual([
    "year",
    "artist",
  ]);
});

test("resolve width uses an override px or the default track sizing", () => {
  const layout = layoutOf(["name", "artist", "year"], [], { artist: 200 });
  expect(resolveColumnWidth(columns[1], layout)).toBe("200px");
  expect(resolveColumnWidth(columns[0], layout)).toBe("minmax(180px, 2fr)");
});

test("build template joins the visible columns' resolved widths", () => {
  const layout = layoutOf(["name", "year"], [], { year: 80 });
  expect(buildTemplate([columns[0], columns[2]], layout)).toBe(
    "minmax(180px, 2fr) 80px"
  );
});

test("move column drops it before the target", () => {
  const layout = layoutOf(["name", "artist", "year"]);
  expect(moveColumn(layout, "year", "name").order).toEqual([
    "year",
    "name",
    "artist",
  ]);
});

test("move column to a null target sends it to the end", () => {
  const layout = layoutOf(["name", "artist", "year"]);
  expect(moveColumn(layout, "name", null).order).toEqual([
    "artist",
    "year",
    "name",
  ]);
});

test("moving a column onto itself is a no-op", () => {
  const layout = layoutOf(["name", "artist", "year"]);
  expect(moveColumn(layout, "name", "name")).toBe(layout);
});

test("clamp width rounds and floors at the minimum", () => {
  expect(clampColumnWidth(199.6)).toBe(200);
  expect(clampColumnWidth(10)).toBe(COLUMN_MIN_WIDTH);
});

test("set width records a clamped px override", () => {
  const layout = layoutOf(["name", "artist", "year"]);
  expect(setColumnWidth(layout, "artist", 5).widths).toEqual({
    artist: COLUMN_MIN_WIDTH,
  });
});

test("reset widths clears overrides but keeps order and hidden", () => {
  const layout = layoutOf(["year", "name", "artist"], ["artist"], { year: 90 });
  const reset = resetColumnWidths(layout);
  expect(reset.widths).toEqual({});
  expect(reset.order).toEqual(["year", "name", "artist"]);
  expect(reset.hidden).toEqual(["artist"]);
});

test("toggle hides a visible column and shows a hidden one", () => {
  const shown = layoutOf(["name", "artist", "year"]);
  const hidden = toggleColumnHidden(shown, "artist", columns);
  expect(hidden.hidden).toEqual(["artist"]);
  expect(toggleColumnHidden(hidden, "artist", columns).hidden).toEqual([]);
});

test("toggle refuses to hide the last visible column", () => {
  const layout = layoutOf(["name", "artist", "year"], ["name", "artist"]);
  expect(toggleColumnHidden(layout, "year", columns)).toBe(layout);
});

test("normalize repairs a partial or garbage stored value", () => {
  expect(normalizeTrackLayout(null).order).toEqual(defaultTrackLayout().order);
  const normalized = normalizeTrackLayout({
    order: ["year", 5, "name"],
    hidden: ["artist", true],
    widths: { year: 90, name: "wide", bad: 10 },
  });
  expect(normalized.order[0]).toBe("year");
  expect(normalized.hidden).toContain("artist");
  expect(normalized.widths.year).toBe(90);
  expect(normalized.widths.name).toBeUndefined();
});
