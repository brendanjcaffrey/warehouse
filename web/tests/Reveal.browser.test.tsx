import { useCallback, useRef, useState } from "react";
import { afterEach, expect, test } from "vitest";
import { cleanup, render, waitFor } from "@testing-library/react";
import { Provider, createStore } from "jotai";
import { FixedSizeList } from "react-window";
import { RevealTarget, revealTargetAtom } from "../src/State";
import { useDetailTrackReveal, useTrackListReveal } from "../src/Reveal";
import { Track } from "../src/Library";

afterEach(() => cleanup());

function track(id: string): Track {
  return { id } as Track;
}

// a store seeded with the reveal so the hooks fire on mount, the way a view does
// when navigation lands on it mid-reveal
function seededStore(reveal: RevealTarget) {
  const store = createStore();
  store.set(revealTargetAtom, reveal);
  return store;
}

const LIST_HEIGHT = 300;
const ROW_HEIGHT = 30;

// a virtualized songs list wired through the real reveal hook, mirroring
// TrackList's own wiring in miniature
function VirtualList({ rows }: { rows: Track[] }) {
  const listRef = useRef<FixedSizeList>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const revealTrack = useCallback((trackId: string, index: number) => {
    setSelectedId(trackId);
    listRef.current?.scrollToItem(index, "center");
  }, []);
  useTrackListReveal(undefined, rows.length > 0, rows, revealTrack);
  return (
    <div data-testid="list">
      <FixedSizeList
        ref={listRef}
        height={LIST_HEIGHT}
        width={400}
        itemCount={rows.length}
        itemSize={ROW_HEIGHT}
      >
        {({ index, style }) => {
          const row = rows[index];
          return (
            <div
              data-track-id={row.id}
              data-selected={row.id === selectedId}
              style={style}
            >
              {row.id}
            </div>
          );
        }}
      </FixedSizeList>
    </div>
  );
}

test("a go-to-song scrolls an off-screen virtualized row into view and selects it", async () => {
  const rows = Array.from({ length: 200 }, (_, i) => track(`t${i}`));
  const store = seededStore({ trackId: "t120", view: "songs" });
  render(
    <Provider store={store}>
      <VirtualList rows={rows} />
    </Provider>
  );

  // row 120 is far outside the initial window, so react-window only renders it
  // once the hook has actually scrolled the list to it
  const row = await waitFor(() => {
    const found = document.querySelector('[data-track-id="t120"]');
    expect(found).not.toBeNull();
    return found as HTMLElement;
  });

  expect(row.getAttribute("data-selected")).toBe("true");

  const listRect = document
    .querySelector('[data-testid="list"]')!
    .getBoundingClientRect();
  const rowRect = row.getBoundingClientRect();
  // fully within the viewport and roughly centred, as scrollToItem("center") asks
  expect(rowRect.top).toBeGreaterThanOrEqual(listRect.top - 1);
  expect(rowRect.bottom).toBeLessThanOrEqual(listRect.bottom + 1);
  const rowCentre = rowRect.top + rowRect.height / 2;
  const listCentre = listRect.top + listRect.height / 2;
  expect(Math.abs(rowCentre - listCentre)).toBeLessThan(ROW_HEIGHT);

  // the reveal has been consumed so it can't fire again on the next navigation
  expect(store.get(revealTargetAtom)).toBeNull();
});

// a detail track view scrolling by data-track-id, mirroring useTrackListNav
function DetailList({ tracks }: { tracks: Track[] }) {
  const containerRef = useRef<HTMLDivElement>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  useDetailTrackReveal("artists", tracks, containerRef, setSelectedId);
  return (
    <div
      ref={containerRef}
      data-testid="scroll"
      style={{ height: 200, overflow: "auto" }}
    >
      {tracks.map((t) => (
        <div
          key={t.id}
          data-track-id={t.id}
          data-selected={t.id === selectedId}
          style={{ height: 40 }}
        >
          {t.id}
        </div>
      ))}
    </div>
  );
}

test("a go-to on a detail view scrolls the track into the middle by its id", async () => {
  const tracks = Array.from({ length: 60 }, (_, i) => track(`t${i}`));
  const store = seededStore({ trackId: "t40", view: "artists" });
  render(
    <Provider store={store}>
      <DetailList tracks={tracks} />
    </Provider>
  );

  const container = document.querySelector(
    '[data-testid="scroll"]'
  ) as HTMLElement;
  const row = document.querySelector('[data-track-id="t40"]') as HTMLElement;

  await waitFor(() => {
    // row 40 sits well below the fold, so a non-zero scroll proves scrollIntoView
    // actually moved the container to it
    expect(container.scrollTop).toBeGreaterThan(0);
  });

  const containerRect = container.getBoundingClientRect();
  const rowRect = row.getBoundingClientRect();
  expect(rowRect.top).toBeGreaterThanOrEqual(containerRect.top - 1);
  expect(rowRect.bottom).toBeLessThanOrEqual(containerRect.bottom + 1);
  expect(row.getAttribute("data-selected")).toBe("true");
  expect(store.get(revealTargetAtom)).toBeNull();
});
