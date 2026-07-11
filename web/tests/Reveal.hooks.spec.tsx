import { ReactNode } from "react";
import { afterEach, beforeAll, expect, test, vi } from "vitest";
import { cleanup, renderHook } from "@testing-library/react";
import { Provider, createStore } from "jotai";
import { RevealTarget, revealTargetAtom } from "../src/State";
import {
  useDetailTrackReveal,
  useRevealListSelection,
  useTrackListReveal,
} from "../src/Reveal";
import { Track } from "../src/Library";

// jsdom has no layout, so scrollIntoView is unimplemented and CSS.escape is
// absent; stub both so the detail hook can run (a real browser has both, which
// the browser-mode test exercises for real)
beforeAll(() => {
  Element.prototype.scrollIntoView = vi.fn();
  if (!globalThis.CSS) {
    globalThis.CSS = { escape: (value: string) => value } as typeof CSS;
  }
});

afterEach(() => cleanup());

// only the id matters to the reveal hooks
function track(id: string): Track {
  return { id } as Track;
}

// a fresh store per render so the atom set in one test can't leak into another
function withStore(initial: RevealTarget | null) {
  const store = createStore();
  store.set(revealTargetAtom, initial);
  const wrapper = ({ children }: { children: ReactNode }) => (
    <Provider store={store}>{children}</Provider>
  );
  return { store, wrapper };
}

test("list selection selects the target and scrolls to its row", () => {
  const { store, wrapper } = withStore({
    trackId: "t1",
    view: "artists",
    selectionId: "Pixies",
  });
  const onSelect = vi.fn();
  const scrollToIndex = vi.fn();
  renderHook(
    () =>
      useRevealListSelection(
        "artists",
        ["Blur", "Pixies", "Oasis"],
        null,
        onSelect,
        scrollToIndex
      ),
    { wrapper }
  );
  expect(onSelect).toHaveBeenCalledWith("Pixies");
  expect(scrollToIndex).toHaveBeenCalledWith(1);
  // the parent list leaves the reveal for the detail view to consume
  expect(store.get(revealTargetAtom)).not.toBeNull();
});

test("list selection skips reselecting when already selected but still scrolls", () => {
  const { wrapper } = withStore({
    trackId: "t1",
    view: "albums",
    selectionId: "Doolittle",
  });
  const onSelect = vi.fn();
  const scrollToIndex = vi.fn();
  renderHook(
    () =>
      useRevealListSelection(
        "albums",
        ["Doolittle"],
        "Doolittle",
        onSelect,
        scrollToIndex
      ),
    { wrapper }
  );
  expect(onSelect).not.toHaveBeenCalled();
  expect(scrollToIndex).toHaveBeenCalledWith(0);
});

test("list selection selects but does not scroll when the row isn't loaded yet", () => {
  const { wrapper } = withStore({
    trackId: "t1",
    view: "artists",
    selectionId: "Pixies",
  });
  const onSelect = vi.fn();
  const scrollToIndex = vi.fn();
  renderHook(
    () =>
      useRevealListSelection(
        "artists",
        ["Blur"],
        null,
        onSelect,
        scrollToIndex
      ),
    { wrapper }
  );
  expect(onSelect).toHaveBeenCalledWith("Pixies");
  expect(scrollToIndex).not.toHaveBeenCalled();
});

test("list selection ignores a reveal aimed at another view", () => {
  const { wrapper } = withStore({
    trackId: "t1",
    view: "albums",
    selectionId: "Doolittle",
  });
  const onSelect = vi.fn();
  const scrollToIndex = vi.fn();
  renderHook(
    () =>
      useRevealListSelection(
        "artists",
        ["Doolittle"],
        null,
        onSelect,
        scrollToIndex
      ),
    { wrapper }
  );
  expect(onSelect).not.toHaveBeenCalled();
  expect(scrollToIndex).not.toHaveBeenCalled();
});

test("track list reveals a loaded track and clears the request", () => {
  const { store, wrapper } = withStore({ trackId: "t2", view: "songs" });
  const onReveal = vi.fn();
  renderHook(
    () =>
      useTrackListReveal(undefined, true, [track("t1"), track("t2")], onReveal),
    { wrapper }
  );
  expect(onReveal).toHaveBeenCalledWith("t2", 1);
  expect(store.get(revealTargetAtom)).toBeNull();
});

test("track list waits for tracks to load before consuming the reveal", () => {
  const { store, wrapper } = withStore({ trackId: "t2", view: "songs" });
  const onReveal = vi.fn();
  renderHook(() => useTrackListReveal(undefined, false, [], onReveal), {
    wrapper,
  });
  expect(onReveal).not.toHaveBeenCalled();
  // still pending, so the reveal survives until the tracks arrive
  expect(store.get(revealTargetAtom)).not.toBeNull();
});

test("track list clears a reveal for a track it doesn't hold without selecting", () => {
  const { store, wrapper } = withStore({ trackId: "gone", view: "songs" });
  const onReveal = vi.fn();
  renderHook(
    () => useTrackListReveal(undefined, true, [track("t1")], onReveal),
    { wrapper }
  );
  expect(onReveal).not.toHaveBeenCalled();
  expect(store.get(revealTargetAtom)).toBeNull();
});

test("a playlist only consumes a reveal carrying its own id", () => {
  const { store, wrapper } = withStore({
    trackId: "t1",
    view: "playlist",
    selectionId: "jazz",
  });
  const onReveal = vi.fn();
  renderHook(() => useTrackListReveal("rock", true, [track("t1")], onReveal), {
    wrapper,
  });
  expect(onReveal).not.toHaveBeenCalled();
  // the reveal belongs to another playlist, so this one leaves it alone
  expect(store.get(revealTargetAtom)).not.toBeNull();
});

test("detail view selects the track, scrolls to it and clears the reveal", () => {
  const { store, wrapper } = withStore({ trackId: "t1", view: "artists" });
  const container = document.createElement("div");
  const row = document.createElement("div");
  row.setAttribute("data-track-id", "t1");
  container.appendChild(row);
  const scrollSpy = vi.spyOn(row, "scrollIntoView");
  const onSelect = vi.fn();
  renderHook(
    () =>
      useDetailTrackReveal(
        "artists",
        [track("t1")],
        { current: container },
        onSelect
      ),
    { wrapper }
  );
  expect(onSelect).toHaveBeenCalledWith("t1");
  expect(scrollSpy).toHaveBeenCalledWith({ block: "center" });
  expect(store.get(revealTargetAtom)).toBeNull();
});

test("detail view ignores a track that isn't among its own", () => {
  const { store, wrapper } = withStore({ trackId: "gone", view: "artists" });
  const onSelect = vi.fn();
  renderHook(
    () =>
      useDetailTrackReveal(
        "artists",
        [track("t1")],
        { current: document.createElement("div") },
        onSelect
      ),
    { wrapper }
  );
  expect(onSelect).not.toHaveBeenCalled();
  // still pending; a stale reveal must not be cleared by the wrong view
  expect(store.get(revealTargetAtom)).not.toBeNull();
});
