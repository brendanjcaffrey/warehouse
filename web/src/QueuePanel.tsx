import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { useAtomValue } from "jotai";
import { Offcanvas } from "react-bootstrap";
import { VariableSizeList, ListChildComponentProps } from "react-window";
import AutoSizer from "react-virtualized-auto-sizer";
import library, { Track } from "./Library";
import { player } from "./Player";
import { PlaylistTrack } from "./Types";
import { queueRevisionAtom, updatedTrackAtom } from "./State";
import { repeatAtom } from "./Settings";
import { AlbumArtwork } from "./AlbumSection";
import { useAlbumArtworkRequests } from "./useAlbumArtworkRequests";
import { FileRequestSource } from "./WorkerTypes";

const ARTWORK_SIZE = 40;
const ROW_HEIGHT = 56;
const HEADER_HEIGHT = 30;
const FOOTER_HEIGHT = 44;

// a single resolved row, computed on demand from the model rather than held in a
// materialized list. a track carries which section it sits in so a click plays
// from the right place, and its upcoming position when it is up next
type ResolvedItem =
  | { kind: "header"; label: string }
  | { kind: "footer"; label: string }
  | {
      kind: "track";
      entry: PlaylistTrack;
      section: "history" | "current" | "upcoming";
      upcomingIndex: number;
    };

// a lightweight description of the flat list: the section arrays plus the index
// boundaries between them. rows are derived from this by index, so a track
// change never has to allocate a row per entry in a huge queue
interface QueueModel {
  history: PlaylistTrack[];
  current: PlaylistTrack | undefined;
  upcoming: PlaylistTrack[];
  hasHistory: boolean;
  hasCurrent: boolean;
  hasUpcoming: boolean;
  hasFooter: boolean;
  footerLabel: string;
  currentHeaderIndex: number;
  currentRowIndex: number;
  upcomingHeaderIndex: number;
  upcomingStart: number;
  footerIndex: number;
  count: number;
}

const EMPTY_MODEL: QueueModel = {
  history: [],
  current: undefined,
  upcoming: [],
  hasHistory: false,
  hasCurrent: false,
  hasUpcoming: false,
  hasFooter: false,
  footerLabel: "",
  currentHeaderIndex: 0,
  currentRowIndex: -1,
  upcomingHeaderIndex: 0,
  upcomingStart: 0,
  footerIndex: 0,
  count: 0,
};

// reads the current queue state and lays out the section boundaries. this is
// cheap: it copies the history and slices the upcoming list (both arrays of
// references), but allocates no per-row objects
function buildModel(repeat: string): QueueModel {
  const queue = player().queue;
  const history = queue.history;
  const current = queue.current;
  const upcoming = queue.upcoming;
  const hasHistory = history.length > 0;
  const hasCurrent = !!current;
  const hasUpcoming = upcoming.length > 0;

  const queueLength = (hasCurrent ? 1 : 0) + upcoming.length;
  const hasFooter = repeat === "all" && queueLength > 0;
  const footerLabel = hasFooter
    ? `repeating ${queueLength} ${queueLength === 1 ? "song" : "songs"}`
    : "";

  const historyEnd = hasHistory ? history.length + 1 : 0;
  const currentHeaderIndex = historyEnd;
  const currentRowIndex = hasCurrent ? historyEnd + 1 : -1;
  const currentEnd = historyEnd + (hasCurrent ? 2 : 0);
  const upcomingHeaderIndex = currentEnd;
  const upcomingStart = currentEnd + 1;
  const upcomingEnd = currentEnd + (hasUpcoming ? upcoming.length + 1 : 0);
  const footerIndex = upcomingEnd;
  const count = upcomingEnd + (hasFooter ? 1 : 0);

  return {
    history,
    current,
    upcoming,
    hasHistory,
    hasCurrent,
    hasUpcoming,
    hasFooter,
    footerLabel,
    currentHeaderIndex,
    currentRowIndex,
    upcomingHeaderIndex,
    upcomingStart,
    footerIndex,
    count,
  };
}

// resolves the row at index. o(1): a few boundary comparisons and one array
// lookup, so only the handful of on-screen rows are ever built
function itemAt(model: QueueModel, index: number): ResolvedItem {
  if (model.hasHistory) {
    if (index === 0) {
      return { kind: "header", label: "history" };
    }
    if (index <= model.history.length) {
      return {
        kind: "track",
        entry: model.history[index - 1],
        section: "history",
        upcomingIndex: -1,
      };
    }
  }
  if (model.hasCurrent) {
    if (index === model.currentHeaderIndex) {
      return { kind: "header", label: "now playing" };
    }
    if (index === model.currentRowIndex) {
      return {
        kind: "track",
        entry: model.current!,
        section: "current",
        upcomingIndex: -1,
      };
    }
  }
  if (model.hasUpcoming) {
    if (index === model.upcomingHeaderIndex) {
      return { kind: "header", label: "playing next" };
    }
    const upcomingIndex = index - model.upcomingStart;
    if (upcomingIndex >= 0 && upcomingIndex < model.upcoming.length) {
      return {
        kind: "track",
        entry: model.upcoming[upcomingIndex],
        section: "upcoming",
        upcomingIndex,
      };
    }
  }
  return { kind: "footer", label: model.footerLabel };
}

function rowHeight(item: ResolvedItem): number {
  if (item.kind === "header") {
    return HEADER_HEIGHT;
  }
  if (item.kind === "footer") {
    return FOOTER_HEIGHT;
  }
  return ROW_HEIGHT;
}

// the scroll offset that puts the now playing row in the vertical middle of a
// viewport of the given height, clamped so we never scroll past either end.
// computed analytically from the section sizes, so it stays o(1) on a huge
// queue. when there isn't enough history above to fill half the viewport this
// clamps to 0, leaving the row near the top
function centeredOffset(model: QueueModel, height: number): number {
  const before =
    (model.hasHistory ? HEADER_HEIGHT + model.history.length * ROW_HEIGHT : 0) +
    (model.hasCurrent ? HEADER_HEIGHT : 0);
  const total =
    before +
    (model.hasCurrent ? ROW_HEIGHT : 0) +
    (model.hasUpcoming
      ? HEADER_HEIGHT + model.upcoming.length * ROW_HEIGHT
      : 0) +
    (model.hasFooter ? FOOTER_HEIGHT : 0);
  const ideal = before - (height - ROW_HEIGHT) / 2;
  const maxOffset = Math.max(0, total - height);
  return Math.max(0, Math.min(ideal, maxOffset));
}

interface QueuePanelProps {
  show: boolean;
  onHide: () => void;
}

function trackName(track: Track | undefined): string {
  return track?.name || "unknown track";
}

function trackSubtitle(track: Track | undefined): string {
  if (!track) {
    return "";
  }
  return [track.artistName, track.albumName].filter(Boolean).join(" - ");
}

const NO_WRAP: React.CSSProperties = {
  whiteSpace: "nowrap",
  overflow: "hidden",
  textOverflow: "ellipsis",
};

function SectionHeader({ children }: { children: React.ReactNode }) {
  return (
    <div
      className="px-3 pt-3 pb-1 text-uppercase"
      style={{
        fontSize: "11px",
        letterSpacing: "0.05em",
        color: "var(--bs-secondary-color)",
      }}
    >
      {children}
    </div>
  );
}

function QueueRow({
  style,
  track,
  active,
  onClick,
}: {
  style: React.CSSProperties;
  track: Track | undefined;
  active?: boolean;
  onClick?: () => void;
}) {
  return (
    <div
      style={{ ...style, cursor: onClick ? "pointer" : undefined }}
      role={onClick ? "button" : undefined}
      onClick={onClick}
      className={
        "d-flex align-items-center gap-2 px-3" +
        (onClick ? " list-group-item-action" : "") +
        (active ? " bg-body-secondary" : "")
      }
    >
      {track ? (
        <AlbumArtwork track={track} size={ARTWORK_SIZE} />
      ) : (
        <div
          className="rounded bg-body-secondary flex-shrink-0"
          style={{ width: ARTWORK_SIZE, height: ARTWORK_SIZE }}
        />
      )}
      <div style={{ minWidth: 0, flexGrow: 1 }}>
        <div style={{ fontSize: "14px", ...NO_WRAP }}>{trackName(track)}</div>
        <div
          style={{
            fontSize: "12px",
            color: "var(--bs-secondary-color)",
            ...NO_WRAP,
          }}
        >
          {trackSubtitle(track) || " "}
        </div>
      </div>
    </div>
  );
}

interface RowData {
  model: QueueModel;
  tracksById: Map<string, Track>;
  onPlayHistory: (entry: PlaylistTrack) => void;
  onPlayUpcoming: (index: number) => void;
}

// a stable top-level component so react-window keeps its row instances across
// renders. the varying data comes through itemData, not a fresh closure, which
// is what stops rows (and their artwork) from remounting when the song changes
function Row({ index, style, data }: ListChildComponentProps<RowData>) {
  const { model, tracksById, onPlayHistory, onPlayUpcoming } = data;
  const item = itemAt(model, index);
  if (item.kind === "header") {
    return (
      <div style={style}>
        <SectionHeader>{item.label}</SectionHeader>
      </div>
    );
  }
  if (item.kind === "footer") {
    return (
      <div
        style={style}
        className="d-flex align-items-center justify-content-center"
      >
        <span style={{ fontSize: "12px", color: "var(--bs-secondary-color)" }}>
          {item.label}
        </span>
      </div>
    );
  }
  const track = tracksById.get(item.entry.trackId);
  const onClick =
    item.section === "history"
      ? () => onPlayHistory(item.entry)
      : item.section === "upcoming"
        ? () => onPlayUpcoming(item.upcomingIndex)
        : undefined;
  return (
    <QueueRow
      style={style}
      track={track}
      active={item.section === "current"}
      onClick={onClick}
    />
  );
}

function QueuePanel({ show, onHide }: QueuePanelProps) {
  const revision = useAtomValue(queueRevisionAtom);
  const repeat = useAtomValue(repeatAtom);
  const updatedTrack = useAtomValue(updatedTrackAtom);
  const [tracksById, setTracksById] = useState<Map<string, Track>>(new Map());
  const [range, setRange] = useState({ start: 0, stop: -1 });
  const listRef = useRef<VariableSizeList>(null);

  // whether the user has scrolled the list by hand since it opened; while they
  // have, a track change is left where it is rather than snapping back
  const userScrolledRef = useRef(false);
  // the entry key last snapped to centre, so incidental changes (play next,
  // shuffle) don't re-centre, only a genuine current-track change does
  const centeredKeyRef = useRef<string | null>(null);
  // the panel's previous open state, to spot the open transition
  const prevShowRef = useRef(false);
  // the offset we hand the list as its initial scroll position; react-window
  // echoes it back through onScroll at mount looking just like a user scroll,
  // so we stash it here to recognise and ignore that one event
  const initialOffsetRef = useRef<number | null>(null);
  // the current row's flat index, mirrored for the imperative scroll helper
  const currentIndexRef = useRef(-1);

  // a stable key per queue entry, keyed off the entry object itself. the entries
  // keep their identity as the song changes (advancing just moves the index), so
  // a row that stays put keeps its react instance and its loaded artwork instead
  // of remounting and flashing
  const entryKeys = useRef(new WeakMap<PlaylistTrack, string>());
  const entryKeyCounter = useRef(0);
  const keyForEntry = useCallback((entry: PlaylistTrack) => {
    const existing = entryKeys.current.get(entry);
    if (existing) {
      return existing;
    }
    const key = `entry-${entryKeyCounter.current++}`;
    entryKeys.current.set(entry, key);
    return key;
  }, []);

  // load every track once when the panel opens, in a single transaction, so a
  // 10k queue doesn't fire 10k individual lookups. rows resolve from this map
  useEffect(() => {
    if (!show) {
      return;
    }
    let cancelled = false;
    library()
      .getAllTracks()
      .then((all) => {
        if (!cancelled && all) {
          setTracksById(new Map(all.map((track) => [track.id, track])));
        }
      });
    return () => {
      cancelled = true;
    };
  }, [show]);

  // patch an edited track in place so its row updates without a full reload
  useEffect(() => {
    if (!updatedTrack) {
      return;
    }
    setTracksById((prev) => {
      if (!prev.has(updatedTrack.id)) {
        return prev;
      }
      const next = new Map(prev);
      next.set(updatedTrack.id, updatedTrack);
      return next;
    });
  }, [updatedTrack]);

  // lay out the queue into section boundaries. reading the queue is cheap and
  // this allocates no per-row objects, so it re-runs freely on every queue
  // change while the panel is open. revision is what signals those changes
  const model = useMemo<QueueModel>(() => {
    // revision is the signal that the queue mutated in place; reading it keeps
    // this memo in step with track changes even though buildModel goes straight
    // to the live queue
    void revision;
    if (!show) {
      return EMPTY_MODEL;
    }
    return buildModel(repeat);
  }, [show, revision, repeat]);

  currentIndexRef.current = model.currentRowIndex;

  // scrolls the current track to the middle of the viewport. a no-op when the
  // list isn't mounted yet; on a cold open initialScrollOffset centres it at
  // mount instead
  const centerCurrent = useCallback(() => {
    const list = listRef.current;
    if (!list) {
      return;
    }
    const index = currentIndexRef.current;
    if (index < 0) {
      return;
    }
    list.scrollToItem(index, "center");
  }, []);

  // playing from a row is a deliberate jump, so let the queue re-centre on the
  // new current track even if the user had scrolled away
  const onPlayHistory = useCallback((entry: PlaylistTrack) => {
    userScrolledRef.current = false;
    player().playFromHistory(entry);
  }, []);
  const onPlayUpcoming = useCallback((index: number) => {
    userScrolledRef.current = false;
    player().playFromUpcoming(index);
  }, []);

  // remeasure and re-centre before paint. row heights differ by kind, and a
  // track change inserts a history row mid-list, so every offset below it goes
  // stale; resetting in a layout effect (not a post-paint one) keeps the list
  // from flashing the old offsets. then snap the current track to the middle on
  // open and on a real track change, unless the user has scrolled away
  useLayoutEffect(() => {
    listRef.current?.resetAfterIndex(0);

    const justOpened = show && !prevShowRef.current;
    prevShowRef.current = show;
    if (justOpened) {
      userScrolledRef.current = false;
      centeredKeyRef.current = null;
    }
    if (!show || !model.current) {
      return;
    }

    const key = keyForEntry(model.current);
    if (key === centeredKeyRef.current || userScrolledRef.current) {
      return;
    }
    centeredKeyRef.current = key;
    // if the list is already mounted (a track change, or reopening), snap now;
    // on a cold open it isn't mounted yet and initialScrollOffset handles it
    centerCurrent();
  }, [show, model, centerCurrent, keyForEntry]);

  // only ask the worker for the covers of the rows actually on screen, so
  // opening a huge queue doesn't queue thousands of artwork downloads at once
  const artworkItems = useMemo(() => {
    const seen = new Set<string>();
    const result: { artworkTrack: Track }[] = [];
    for (let i = range.start; i <= range.stop; i++) {
      if (i < 0 || i >= model.count) {
        continue;
      }
      const item = itemAt(model, i);
      if (item.kind !== "track") {
        continue;
      }
      const track = tracksById.get(item.entry.trackId);
      if (track?.artworkFilename && !seen.has(track.artworkFilename)) {
        seen.add(track.artworkFilename);
        result.push({ artworkTrack: track });
      }
    }
    return result;
  }, [range, model, tracksById]);

  useAlbumArtworkRequests(artworkItems, FileRequestSource.QUEUE_ARTWORK);

  const itemSize = useCallback(
    (index: number) => rowHeight(itemAt(model, index)),
    [model]
  );

  const itemKey = useCallback(
    (index: number) => {
      const item = itemAt(model, index);
      if (item.kind === "track") {
        return keyForEntry(item.entry);
      }
      if (item.kind === "footer") {
        return "footer";
      }
      return `${item.label}-header`;
    },
    [model, keyForEntry]
  );

  const onItemsRendered = useCallback(
    ({
      overscanStartIndex,
      overscanStopIndex,
    }: {
      overscanStartIndex: number;
      overscanStopIndex: number;
    }) => {
      setRange({ start: overscanStartIndex, stop: overscanStopIndex });
    },
    []
  );

  // a scroll the list didn't request itself is the user's, so stop auto-centring.
  // our own scrollToItem calls carry scrollUpdateWasRequested; the one exception
  // is the echo of initialScrollOffset at mount, which lands exactly on the
  // offset we asked for, so recognise and skip that rather than treating it as
  // the user grabbing the scrollbar
  const onScroll = useCallback(
    ({
      scrollOffset,
      scrollUpdateWasRequested,
    }: {
      scrollOffset: number;
      scrollUpdateWasRequested: boolean;
    }) => {
      if (scrollUpdateWasRequested) {
        return;
      }
      if (scrollOffset === initialOffsetRef.current) {
        initialOffsetRef.current = null;
        return;
      }
      userScrolledRef.current = true;
    },
    []
  );

  // pass the changing data through itemData so the Row component identity stays
  // stable and react-window can reuse its row instances
  const rowData = useMemo<RowData>(
    () => ({ model, tracksById, onPlayHistory, onPlayUpcoming }),
    [model, tracksById, onPlayHistory, onPlayUpcoming]
  );

  return (
    <Offcanvas show={show} onHide={onHide} placement="end">
      <Offcanvas.Header closeButton>
        <Offcanvas.Title>Queue</Offcanvas.Title>
      </Offcanvas.Header>
      <Offcanvas.Body className="p-0 d-flex flex-column">
        {model.count === 0 ? (
          <p className="text-body-secondary px-3 pt-3">nothing queued</p>
        ) : (
          <div style={{ flex: 1, minHeight: 0 }}>
            <AutoSizer>
              {({ height, width }) => {
                const initialOffset =
                  model.currentRowIndex >= 0
                    ? centeredOffset(model, height)
                    : 0;
                initialOffsetRef.current = initialOffset;
                return (
                  <VariableSizeList
                    ref={listRef}
                    height={height}
                    width={width}
                    itemCount={model.count}
                    itemSize={itemSize}
                    itemData={rowData}
                    itemKey={itemKey}
                    initialScrollOffset={initialOffset}
                    onItemsRendered={onItemsRendered}
                    onScroll={onScroll}
                  >
                    {Row}
                  </VariableSizeList>
                );
              }}
            </AutoSizer>
          </div>
        )}
      </Offcanvas.Body>
    </Offcanvas>
  );
}

export default QueuePanel;
