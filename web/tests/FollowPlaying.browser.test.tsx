import { useCallback, useRef } from "react";
import { afterEach, expect, test } from "vitest";
import { act, cleanup, render, waitFor } from "@testing-library/react";
import { Provider, createStore } from "jotai";
import { FixedSizeList } from "react-window";
import { playingAtom, playingTrackAtom } from "../src/State";
import { useFollowPlaying } from "../src/FollowPlaying";
import PlayingIndicator from "../src/PlayingIndicator";
import { Track } from "../src/Library";

afterEach(() => cleanup());

function track(id: string): Track {
  return { id, name: id } as Track;
}

type Store = ReturnType<typeof createStore>;

function play(store: Store, trackId: string) {
  store.set(playingTrackAtom, {
    track: track(trackId),
    playlistId: "library",
    playlistOffset: 0,
  });
}

// a store already playing `trackId`, the way a view finds the player on mount
function playingStore(trackId: string) {
  const store = createStore();
  store.set(playingAtom, true);
  play(store, trackId);
  return store;
}

// how far a row's centre sits from its scroll container's centre
function offsetFromCentre(row: Element, container: Element): number {
  const rowRect = row.getBoundingClientRect();
  const containerRect = container.getBoundingClientRect();
  return Math.abs(
    rowRect.top +
      rowRect.height / 2 -
      (containerRect.top + containerRect.height / 2)
  );
}

function expectWithin(row: Element, container: Element) {
  const rowRect = row.getBoundingClientRect();
  const containerRect = container.getBoundingClientRect();
  expect(rowRect.top).toBeGreaterThanOrEqual(containerRect.top - 1);
  expect(rowRect.bottom).toBeLessThanOrEqual(containerRect.bottom + 1);
}

const LIST_HEIGHT = 300;
const ROW_HEIGHT = 30;

// a virtualized songs list wired through the real follow hook, mirroring
// TrackList's own wiring in miniature
function VirtualList({ rows }: { rows: Track[] }) {
  const listRef = useRef<FixedSizeList>(null);
  const scrollToPlaying = useCallback(
    (trackId: string) => {
      const index = rows.findIndex((row) => row.id === trackId);
      if (index !== -1) {
        listRef.current?.scrollToItem(index, "center");
      }
    },
    [rows]
  );
  useFollowPlaying(scrollToPlaying);
  return (
    <div data-testid="list">
      <FixedSizeList
        ref={listRef}
        height={LIST_HEIGHT}
        width={400}
        itemCount={rows.length}
        itemSize={ROW_HEIGHT}
      >
        {({ index, style }) => (
          <div data-track-id={rows[index].id} style={style}>
            <PlayingIndicator trackId={rows[index].id} />
            {rows[index].name}
          </div>
        )}
      </FixedSizeList>
    </div>
  );
}

// react-window's own scroll container, the element the list actually scrolls
function scroller(): HTMLElement {
  return document.querySelector('[data-testid="list"]')!
    .firstElementChild as HTMLElement;
}

test("the songs list scrolls to the next track and marks it when playback moves on", async () => {
  const rows = Array.from({ length: 200 }, (_, i) => track(`t${i}`));
  const store = playingStore("t0");
  render(
    <Provider store={store}>
      <VirtualList rows={rows} />
    </Provider>
  );

  // the song ends and the next one starts, far below the fold
  act(() => play(store, "t120"));

  // row 120 is well outside the initial window, so react-window only renders it
  // once the hook has actually scrolled the list to it
  const row = await waitFor(() => {
    const found = document.querySelector('[data-track-id="t120"]');
    expect(found).not.toBeNull();
    return found as HTMLElement;
  });

  expectWithin(row, scroller());
  // scrollToItem("center") puts it in the middle, within a row's slack
  expect(offsetFromCentre(row, scroller())).toBeLessThan(ROW_HEIGHT);

  // and it carries the playing mark, while no other row does
  expect(row.querySelector('[data-testid="playing-indicator"]')).not.toBeNull();
  expect(
    document.querySelectorAll('[data-testid="playing-indicator"]')
  ).toHaveLength(1);
});

test("the songs list stays put when it mounts on a track already playing", async () => {
  const rows = Array.from({ length: 200 }, (_, i) => track(`t${i}`));
  const store = playingStore("t120");
  render(
    <Provider store={store}>
      <VirtualList rows={rows} />
    </Provider>
  );

  // navigating to a view mid-song must not yank it to the playing track; give
  // the effects a frame to run, then confirm the list never left the top
  await act(async () => {
    await new Promise((resolve) => requestAnimationFrame(resolve));
  });
  expect(scroller().scrollTop).toBe(0);
  expect(document.querySelector('[data-track-id="t120"]')).toBeNull();
});

const DETAIL_HEIGHT = 200;
const DETAIL_ROW_HEIGHT = 40;

// an artist/album detail list scrolling by data-track-id, mirroring
// useTrackListNav's wiring
function DetailList({ tracks }: { tracks: Track[] }) {
  const containerRef = useRef<HTMLDivElement>(null);
  const scrollToPlaying = useCallback((trackId: string) => {
    containerRef.current
      ?.querySelector(`[data-track-id="${CSS.escape(trackId)}"]`)
      ?.scrollIntoView({ block: "center" });
  }, []);
  useFollowPlaying(scrollToPlaying);
  return (
    <div
      ref={containerRef}
      data-testid="scroll"
      style={{ height: DETAIL_HEIGHT, overflow: "auto" }}
    >
      {tracks.map((t) => (
        <div
          key={t.id}
          data-track-id={t.id}
          style={{ height: DETAIL_ROW_HEIGHT }}
        >
          <PlayingIndicator trackId={t.id} />
          {t.name}
        </div>
      ))}
    </div>
  );
}

test("an album view scrolls to the next track and marks it when playback moves on", async () => {
  const tracks = Array.from({ length: 60 }, (_, i) => track(`t${i}`));
  const store = playingStore("t0");
  render(
    <Provider store={store}>
      <DetailList tracks={tracks} />
    </Provider>
  );

  const container = document.querySelector(
    '[data-testid="scroll"]'
  ) as HTMLElement;
  expect(container.scrollTop).toBe(0);

  // the user hits next, landing on a track well below the fold
  act(() => play(store, "t40"));

  await waitFor(() => {
    // a non-zero scroll proves scrollIntoView actually moved the container
    expect(container.scrollTop).toBeGreaterThan(0);
  });

  const row = document.querySelector('[data-track-id="t40"]') as HTMLElement;
  expectWithin(row, container);
  expect(offsetFromCentre(row, container)).toBeLessThan(DETAIL_ROW_HEIGHT);
  expect(row.querySelector('[data-testid="playing-indicator"]')).not.toBeNull();
});

test("an album view that doesn't hold the playing track doesn't scroll", async () => {
  const tracks = Array.from({ length: 60 }, (_, i) => track(`t${i}`));
  const store = playingStore("t0");
  render(
    <Provider store={store}>
      <DetailList tracks={tracks} />
    </Provider>
  );

  // playback moved on to a track from some other album, so there is nothing
  // here to scroll to and the list is left alone
  act(() => play(store, "elsewhere"));

  await act(async () => {
    await new Promise((resolve) => requestAnimationFrame(resolve));
  });
  const container = document.querySelector(
    '[data-testid="scroll"]'
  ) as HTMLElement;
  expect(container.scrollTop).toBe(0);
  expect(
    document.querySelectorAll('[data-testid="playing-indicator"]')
  ).toHaveLength(0);
});
