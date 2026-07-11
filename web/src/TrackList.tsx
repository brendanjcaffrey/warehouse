import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { FixedSizeList, ListChildComponentProps } from "react-window";
import AutoSizer from "react-virtualized-auto-sizer";
import { useAtom, useAtomValue } from "jotai";
import { OverlayTrigger, Popover } from "react-bootstrap";
import {
  ArrowCounterclockwise,
  CaretUpFill,
  CaretDownFill,
  Check,
  Funnel,
  FunnelFill,
} from "react-bootstrap-icons";
import { useTypeToSearch } from "./useTypeToSearch";
import { useTrackListTracks } from "./useTrackListTracks";
import { TRACK_COLUMNS, TrackColumn } from "./TrackColumns";
import { cycleSort, sortTracks, SortKey } from "./TrackSort";
import { filterTracks, searchTracks, FilterState } from "./TrackFilter";
import { searchAtom } from "./State";
import { trackLayoutAtom } from "./Settings";
import {
  buildTemplate,
  COLUMN_MIN_WIDTH,
  moveColumn,
  reconcileLayout,
  resetColumnWidths,
  setColumnWidth,
  toggleColumnHidden,
  visibleColumns,
} from "./TrackLayout";

interface TrackListProps {
  // when omitted the whole library is shown, otherwise just the playlist's tracks
  playlistId?: string;
}

// tall enough for a star-rating row without crowding
const ROW_HEIGHT = 32;
const HEADER_HEIGHT = 32;

// where a dragged column would land relative to the header it's hovering over
type DropSide = "before" | "after";
interface DropTarget {
  columnId: string;
  side: DropSide;
}

// the body list scrolls and the header does not, so the header is wider by one
// scrollbar and its columns drift right of the body's. measure the scrollbar
// once and pad the header by it so both share the same content width. returns 0
// for overlay scrollbars, where there is nothing to reserve
function measureScrollbarWidth(): number {
  const outer = document.createElement("div");
  outer.style.visibility = "hidden";
  outer.style.overflow = "scroll";
  outer.style.width = "100px";
  outer.style.height = "100px";
  document.body.appendChild(outer);
  const width = outer.offsetWidth - outer.clientWidth;
  document.body.removeChild(outer);
  return width;
}

// the funnel that sits after each column name and opens a popover with that
// column's filter box. it fills and turns primary when a filter is set so an
// active column reads at a glance, and it never shrinks, so a tight column
// trims its name rather than the icon
function ColumnFilter({
  column,
  value,
  onChange,
}: {
  column: TrackColumn;
  value: string;
  onChange: (value: string) => void;
}) {
  const active = value.trim() !== "";
  const popover = (
    <Popover>
      <Popover.Body className="p-2">
        <input
          autoFocus
          type="text"
          className="form-control form-control-sm"
          style={{ width: 200 }}
          placeholder={column.type === "number" ? "e.g. >2000" : "contains"}
          aria-label={`filter ${column.header}`}
          value={value}
          onChange={(event) => onChange(event.target.value)}
          onKeyDown={(event) => event.stopPropagation()}
        />
        {column.type === "number" && (
          <div className="text-secondary small mt-1">
            {"use > < >= <= = or a low-high range"}
          </div>
        )}
      </Popover.Body>
    </Popover>
  );

  return (
    <OverlayTrigger
      trigger="click"
      rootClose
      placement="bottom"
      overlay={popover}
    >
      <span
        role="button"
        aria-label={`filter ${column.header}`}
        className={`d-inline-flex flex-shrink-0 ${
          active ? "text-primary" : "text-secondary opacity-50"
        }`}
        style={{ cursor: "pointer" }}
      >
        {active ? <FunnelFill size={11} /> : <Funnel size={11} />}
      </span>
    </OverlayTrigger>
  );
}

// the menu that opens on right-clicking a header: a checklist to show or hide
// columns the itunes way, plus a reset for any dragged widths. it closes on an
// outside click or escape
function ColumnMenu({
  position,
  hidden,
  hasCustomWidths,
  onToggle,
  onResetSizes,
  onClose,
}: {
  position: { x: number; y: number };
  hidden: string[];
  hasCustomWidths: boolean;
  onToggle: (columnId: string) => void;
  onResetSizes: () => void;
  onClose: () => void;
}) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const onPointerDown = (event: MouseEvent) => {
      if (ref.current && !ref.current.contains(event.target as Node)) {
        onClose();
      }
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        onClose();
      }
    };
    window.addEventListener("mousedown", onPointerDown);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("mousedown", onPointerDown);
      window.removeEventListener("keydown", onKey);
    };
  }, [onClose]);

  const hiddenSet = new Set(hidden);
  const visibleCount = TRACK_COLUMNS.length - hiddenSet.size;

  return (
    <div
      ref={ref}
      role="menu"
      className="dropdown-menu show shadow-sm"
      style={{
        position: "fixed",
        top: position.y,
        left: position.x,
        zIndex: 1080,
        minWidth: 180,
      }}
    >
      <h6 className="dropdown-header">columns</h6>
      {TRACK_COLUMNS.map((column) => {
        const isVisible = !hiddenSet.has(column.id);
        // never let the last visible column be turned off
        const disabled = isVisible && visibleCount <= 1;
        return (
          <button
            key={column.id}
            type="button"
            role="menuitemcheckbox"
            aria-checked={isVisible}
            disabled={disabled}
            onClick={() => onToggle(column.id)}
            className="dropdown-item d-flex align-items-center gap-2"
          >
            <Check
              size={15}
              className={`flex-shrink-0 text-primary${
                isVisible ? "" : " invisible"
              }`}
            />
            {column.header}
          </button>
        );
      })}
      <div className="dropdown-divider" />
      <button
        type="button"
        role="menuitem"
        disabled={!hasCustomWidths}
        onClick={onResetSizes}
        className="dropdown-item d-flex align-items-center gap-2"
      >
        <ArrowCounterclockwise size={15} className="flex-shrink-0" />
        reset column widths
      </button>
    </div>
  );
}

// virtualized columnar list shared by the songs and playlist views. only the
// visible rows mount, so it scrolls a full library smoothly, and its columns
// sort, filter, resize, reorder and hide, all persisted through settings storage
function TrackList({ playlistId }: TrackListProps) {
  const tracks = useTrackListTracks(playlistId);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [sortKeys, setSortKeys] = useState<SortKey[]>([]);
  const [filters, setFilters] = useState<FilterState>({});
  const search = useAtomValue(searchAtom);
  const [scrollbarWidth] = useState(measureScrollbarWidth);
  const [storedLayout, setStoredLayout] = useAtom(trackLayoutAtom);
  // the width of a column while it's being dragged, before we persist on release
  const [resizing, setResizing] = useState<{
    columnId: string;
    width: number;
  } | null>(null);
  const [dragColumnId, setDragColumnId] = useState<string | null>(null);
  const [dropTarget, setDropTarget] = useState<DropTarget | null>(null);
  const [menu, setMenu] = useState<{ x: number; y: number } | null>(null);
  const listRef = useRef<FixedSizeList>(null);

  // fold the saved layout onto the current column set, then take the columns we
  // actually draw in their chosen order with hidden ones removed
  const layout = useMemo(
    () => reconcileLayout(storedLayout, TRACK_COLUMNS),
    [storedLayout]
  );
  const columns = useMemo(
    () => visibleColumns(layout, TRACK_COLUMNS),
    [layout]
  );

  // the nav search box narrows across name/artist/album/genre before the
  // per-column filters and the sort, so all three compose into the shown rows
  const rows = useMemo(() => {
    const searched = searchTracks(tracks, search, TRACK_COLUMNS);
    const filtered = filterTracks(searched, filters, TRACK_COLUMNS);
    return sortTracks(filtered, sortKeys, TRACK_COLUMNS);
  }, [tracks, search, filters, sortKeys]);

  // one shared grid template keeps the header cells lined up with the body cells;
  // it reflects the live drag width so the column tracks the cursor as you resize
  const template = useMemo(() => {
    const effective = resizing
      ? setColumnWidth(layout, resizing.columnId, resizing.width)
      : layout;
    return buildTemplate(columns, effective);
  }, [columns, layout, resizing]);

  const sortByColumn = useCallback(
    (columnId: string, additive: boolean) =>
      setSortKeys((prev) => cycleSort(prev, columnId, additive)),
    []
  );

  const setColumnFilter = useCallback(
    (columnId: string, value: string) =>
      setFilters((prev) => ({ ...prev, [columnId]: value })),
    []
  );

  // hiding a column also clears any sort or filter it held, so the grid can't be
  // left filtering by a column the user can no longer see or clear
  const toggleColumn = useCallback(
    (columnId: string) => {
      const wasHidden = layout.hidden.includes(columnId);
      const next = toggleColumnHidden(layout, columnId, TRACK_COLUMNS);
      if (next === layout) {
        return;
      }
      setStoredLayout(next);
      if (!wasHidden) {
        setFilters((prev) => {
          if (!(columnId in prev)) {
            return prev;
          }
          const rest = { ...prev };
          delete rest[columnId];
          return rest;
        });
        setSortKeys((prev) => prev.filter((key) => key.columnId !== columnId));
      }
    },
    [layout, setStoredLayout]
  );

  const resetColumnSizes = useCallback(() => {
    setStoredLayout((prev) =>
      resetColumnWidths(reconcileLayout(prev, TRACK_COLUMNS))
    );
    setMenu(null);
  }, [setStoredLayout]);

  const startColumnResize = useCallback(
    (event: React.MouseEvent, columnId: string) => {
      event.preventDefault();
      event.stopPropagation();
      const cell = (event.currentTarget as HTMLElement).parentElement;
      const startX = event.clientX;
      const startWidth = cell
        ? cell.getBoundingClientRect().width
        : COLUMN_MIN_WIDTH;
      let latest = startWidth;
      setResizing({ columnId, width: startWidth });

      const onMove = (moveEvent: MouseEvent) => {
        latest = Math.max(
          COLUMN_MIN_WIDTH,
          startWidth + (moveEvent.clientX - startX)
        );
        setResizing({ columnId, width: latest });
      };
      const onUp = () => {
        window.removeEventListener("mousemove", onMove);
        window.removeEventListener("mouseup", onUp);
        document.body.style.userSelect = "";
        document.body.style.cursor = "";
        setStoredLayout((prev) =>
          setColumnWidth(reconcileLayout(prev, TRACK_COLUMNS), columnId, latest)
        );
        setResizing(null);
      };

      window.addEventListener("mousemove", onMove);
      window.addEventListener("mouseup", onUp);
      document.body.style.userSelect = "none";
      document.body.style.cursor = "col-resize";
    },
    [setStoredLayout]
  );

  // drop the dragged column before or after the header it was released on, using
  // the visible order so it lands next to the neighbour the user sees
  const dropColumn = useCallback(
    (target: DropTarget | null) => {
      if (!dragColumnId || !target || target.columnId === dragColumnId) {
        return;
      }
      let targetId: string | null = target.columnId;
      if (target.side === "after") {
        const index = columns.findIndex((c) => c.id === target.columnId);
        targetId =
          index >= 0 && index + 1 < columns.length
            ? columns[index + 1].id
            : null;
      }
      setStoredLayout((prev) =>
        moveColumn(reconcileLayout(prev, TRACK_COLUMNS), dragColumnId, targetId)
      );
    },
    [columns, dragColumnId, setStoredLayout]
  );

  const selectIndex = useCallback(
    (index: number) => {
      const track = rows[index];
      if (!track) {
        return;
      }
      setSelectedId(track.id);
      listRef.current?.scrollToItem(index, "smart");
    },
    [rows]
  );

  // type-to-search follows the primary sort so typing jumps down the column
  // you're sorted by; with no text sort it falls back to the track sort name
  const searchColumn = useMemo(() => {
    const primary = sortKeys[0];
    const column = TRACK_COLUMNS.find((c) => c.id === primary?.columnId);
    return column && column.type === "text" ? column : null;
  }, [sortKeys]);
  const searchNames = useMemo(
    () =>
      rows.map((track) =>
        searchColumn
          ? String(searchColumn.value(track))
          : track.sortName || track.name
      ),
    [rows, searchColumn]
  );
  const handleTypeSearch = useTypeToSearch(searchNames, selectIndex);

  const handleKeyDown = useCallback(
    (event: React.KeyboardEvent) => {
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        const current = rows.findIndex((track) => track.id === selectedId);
        const delta = event.key === "ArrowDown" ? 1 : -1;
        selectIndex(current === -1 ? 0 : current + delta);
        return;
      }
      if (handleTypeSearch(event)) {
        event.preventDefault();
      }
    },
    [rows, selectedId, selectIndex, handleTypeSearch]
  );

  const Row = useCallback(
    ({ index, style }: ListChildComponentProps) => {
      const track = rows[index];
      const isSelected = track.id === selectedId;
      return (
        <div
          role="row"
          aria-selected={isSelected}
          onClick={() => selectIndex(index)}
          className={isSelected ? "table-active" : ""}
          style={{
            ...style,
            display: "grid",
            gridTemplateColumns: template,
            alignItems: "center",
            cursor: "pointer",
          }}
        >
          {columns.map((column) => (
            <div
              key={column.id}
              role="cell"
              className={`px-2 text-truncate${
                column.align === "end" ? " text-end" : ""
              }`}
            >
              {column.render(track)}
            </div>
          ))}
        </div>
      );
    },
    [columns, rows, selectedId, selectIndex, template]
  );

  return (
    <div
      className="h-100"
      role="grid"
      aria-label={playlistId ? "playlist tracks" : "songs"}
      tabIndex={0}
      onKeyDown={handleKeyDown}
    >
      <AutoSizer>
        {({ height, width }) => (
          <div style={{ width }}>
            <div
              role="row"
              className="d-grid border-bottom text-secondary small fw-semibold bg-body"
              style={{
                gridTemplateColumns: template,
                height: HEADER_HEIGHT,
                alignItems: "center",
                paddingRight: scrollbarWidth,
              }}
            >
              {columns.map((column) => {
                const sortIndex = sortKeys.findIndex(
                  (key) => key.columnId === column.id
                );
                const sortKey = sortIndex === -1 ? null : sortKeys[sortIndex];
                const isDropTarget =
                  dropTarget?.columnId === column.id &&
                  dragColumnId !== null &&
                  dragColumnId !== column.id;
                const dropClass = isDropTarget
                  ? dropTarget?.side === "after"
                    ? " track-column-drop-after"
                    : " track-column-drop-before"
                  : "";
                return (
                  <div
                    key={column.id}
                    role="columnheader"
                    aria-sort={
                      sortKey
                        ? sortKey.direction === "asc"
                          ? "ascending"
                          : "descending"
                        : "none"
                    }
                    className={`position-relative px-2 d-flex align-items-center gap-1 user-select-none${
                      column.align === "end" ? " justify-content-end" : ""
                    }${dragColumnId === column.id ? " track-column-dragging" : ""}${dropClass}`}
                    style={{ cursor: "grab" }}
                    draggable
                    onDragStart={(event) => {
                      // let the resize handle own its own drag rather than
                      // starting a column move
                      const target = event.target as HTMLElement;
                      if (target.closest(".track-column-resize-handle")) {
                        event.preventDefault();
                        return;
                      }
                      event.dataTransfer.effectAllowed = "move";
                      setDragColumnId(column.id);
                    }}
                    onDragEnd={() => {
                      setDragColumnId(null);
                      setDropTarget(null);
                    }}
                    onContextMenu={(event) => {
                      event.preventDefault();
                      setMenu({ x: event.clientX, y: event.clientY });
                    }}
                    onDragOver={(event) => {
                      if (!dragColumnId) {
                        return;
                      }
                      event.preventDefault();
                      const rect = event.currentTarget.getBoundingClientRect();
                      const side: DropSide =
                        event.clientX < rect.left + rect.width / 2
                          ? "before"
                          : "after";
                      setDropTarget({ columnId: column.id, side });
                    }}
                    onDrop={(event) => {
                      event.preventDefault();
                      dropColumn(dropTarget);
                      setDragColumnId(null);
                      setDropTarget(null);
                    }}
                  >
                    <span
                      onClick={(event) =>
                        sortByColumn(column.id, event.shiftKey)
                      }
                      className="d-inline-flex align-items-center gap-1"
                      style={{ minWidth: 0, cursor: "pointer" }}
                    >
                      <span className="text-truncate">{column.header}</span>
                      {sortKey &&
                        (sortKey.direction === "asc" ? (
                          <CaretUpFill size={9} className="flex-shrink-0" />
                        ) : (
                          <CaretDownFill size={9} className="flex-shrink-0" />
                        ))}
                      {sortKey && sortKeys.length > 1 && (
                        <span className="flex-shrink-0" style={{ fontSize: 9 }}>
                          {sortIndex + 1}
                        </span>
                      )}
                    </span>
                    <ColumnFilter
                      column={column}
                      value={filters[column.id] ?? ""}
                      onChange={(value) => setColumnFilter(column.id, value)}
                    />
                    <span
                      className="track-column-resize-handle"
                      onMouseDown={(event) =>
                        startColumnResize(event, column.id)
                      }
                    />
                  </div>
                );
              })}
            </div>
            <FixedSizeList
              ref={listRef}
              height={Math.max(0, height - HEADER_HEIGHT)}
              width={width}
              itemCount={rows.length}
              itemSize={ROW_HEIGHT}
              style={{ overflowY: "scroll" }}
            >
              {Row}
            </FixedSizeList>
          </div>
        )}
      </AutoSizer>
      {menu && (
        <ColumnMenu
          position={menu}
          hidden={layout.hidden}
          hasCustomWidths={Object.keys(layout.widths).length > 0}
          onToggle={toggleColumn}
          onResetSizes={resetColumnSizes}
          onClose={() => setMenu(null)}
        />
      )}
    </div>
  );
}

export default TrackList;
