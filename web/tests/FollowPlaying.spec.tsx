import { ReactNode } from "react";
import { afterEach, expect, test, vi } from "vitest";
import { act, cleanup, renderHook } from "@testing-library/react";
import { Provider, createStore } from "jotai";
import { playingTrackAtom } from "../src/State";
import { useFollowPlaying } from "../src/FollowPlaying";
import { Track } from "../src/Library";

afterEach(() => cleanup());

// only the id matters to the follow hook
function track(id: string): Track {
  return { id } as Track;
}

type Store = ReturnType<typeof createStore>;

function play(store: Store, trackId: string | undefined) {
  store.set(
    playingTrackAtom,
    trackId
      ? { track: track(trackId), playlistId: "library", playlistOffset: 0 }
      : undefined
  );
}

// a store already playing `trackId` when the view mounts, as a view finds the
// player when you navigate to it mid-song
function withStore(trackId: string | undefined) {
  const store = createStore();
  play(store, trackId);
  const wrapper = ({ children }: { children: ReactNode }) => (
    <Provider store={store}>{children}</Provider>
  );
  return { store, wrapper };
}

test("the list scrolls to the next track when playback moves on", () => {
  const { store, wrapper } = withStore("t1");
  const onScroll = vi.fn();
  renderHook(() => useFollowPlaying(onScroll), { wrapper });

  act(() => play(store, "t2"));
  expect(onScroll).toHaveBeenCalledWith("t2");
});

test("mounting mid-song does not yank the list to what is already playing", () => {
  const { wrapper } = withStore("t1");
  const onScroll = vi.fn();
  renderHook(() => useFollowPlaying(onScroll), { wrapper });

  // the user navigated here, or was sent here by a "go to"; the list stays put
  expect(onScroll).not.toHaveBeenCalled();
});

test("a view mounted while stopped follows the first track played into it", () => {
  const { store, wrapper } = withStore(undefined);
  const onScroll = vi.fn();
  renderHook(() => useFollowPlaying(onScroll), { wrapper });

  act(() => play(store, "t1"));
  expect(onScroll).toHaveBeenCalledWith("t1");
});

test("re-rendering on the same track does not scroll again", () => {
  const { store, wrapper } = withStore("t1");
  const onScroll = vi.fn();
  const { rerender } = renderHook(() => useFollowPlaying(onScroll), {
    wrapper,
  });

  act(() => play(store, "t2"));
  expect(onScroll).toHaveBeenCalledTimes(1);

  // a rating edit, a filter change, anything that re-renders the list: the
  // track hasn't changed, so the user's scroll position is left alone
  rerender();
  act(() => play(store, "t2"));
  expect(onScroll).toHaveBeenCalledTimes(1);
});

test("stopping playback leaves the list where it is", () => {
  const { store, wrapper } = withStore("t1");
  const onScroll = vi.fn();
  renderHook(() => useFollowPlaying(onScroll), { wrapper });

  act(() => play(store, undefined));
  expect(onScroll).not.toHaveBeenCalled();
});
