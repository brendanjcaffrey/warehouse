import { afterEach, expect, test, vi } from "vitest";
import { KeyboardEvent } from "react";
import { act, cleanup, renderHook } from "@testing-library/react";
import { store, typeToShowInProgressAtom } from "../src/State";
import {
  isQueryKey,
  nearestMatch,
  useTypeToSearch,
} from "../src/useTypeToSearch";

const noModifiers = { metaKey: false, ctrlKey: false, altKey: false };

const artists = ["beatles", "grateful dead", "led zeppelin", "the who"];

test("prefers a prefix match", () => {
  expect(nearestMatch(artists, "led")).toBe(2);
});

test("matches case-insensitively against lowercase queries", () => {
  expect(nearestMatch(["Led Zeppelin", "Metallica"], "led")).toBe(0);
});

test("falls back to a substring match when nothing starts with the query", () => {
  expect(nearestMatch(artists, "who")).toBe(3);
});

test("prefers the earliest prefix match over a later substring match", () => {
  expect(nearestMatch(["abba", "led zeppelin", "led"], "led")).toBe(1);
});

test("returns -1 when there is no match", () => {
  expect(nearestMatch(artists, "xyz")).toBe(-1);
});

test("returns -1 for an empty query", () => {
  expect(nearestMatch(artists, "")).toBe(-1);
});

test("accepts a printable character as a query key", () => {
  expect(isQueryKey("a", false, noModifiers)).toBe(true);
});

test("ignores non-printable keys", () => {
  expect(isQueryKey("Enter", false, noModifiers)).toBe(false);
  expect(isQueryKey("ArrowDown", false, noModifiers)).toBe(false);
});

test("ignores keys pressed with a modifier", () => {
  expect(isQueryKey("a", false, { ...noModifiers, metaKey: true })).toBe(false);
});

test("treats a bare space as the play/pause shortcut, not a query key", () => {
  expect(isQueryKey(" ", false, noModifiers)).toBe(false);
});

test("keeps a space inside an in-progress query for multi-word matches", () => {
  expect(isQueryKey(" ", true, noModifiers)).toBe(true);
});

afterEach(() => {
  cleanup();
  vi.useRealTimers();
  store.set(typeToShowInProgressAtom, false);
});

// only the fields the hook reads off the keyboard event
function keyEvent(key: string): KeyboardEvent {
  return {
    key,
    metaKey: false,
    ctrlKey: false,
    altKey: false,
  } as KeyboardEvent;
}

function typed(names: string[]) {
  const matches: number[] = [];
  const { result, unmount } = renderHook(() =>
    useTypeToSearch(names, (index) => matches.push(index))
  );
  const type = (text: string) =>
    act(() => {
      for (const key of text) {
        result.current(keyEvent(key));
      }
    });
  return { matches, type, handle: () => result.current, unmount };
}

const tracks = ["acid rain", "that acid feeling", "thunder"];

test("types a multi-word query through a space", () => {
  const { matches, type } = typed(tracks);
  type("that acid");
  expect(matches.at(-1)).toBe(1);
});

test("flags a query in progress so space is not play/pause", () => {
  const { type, handle } = typed(tracks);
  expect(store.get(typeToShowInProgressAtom)).toBe(false);
  type("t");
  expect(store.get(typeToShowInProgressAtom)).toBe(true);
  // the space is consumed by the query rather than falling through
  expect(handle()(keyEvent(" "))).toBe(true);
});

test("ignores a space when no query is under way", () => {
  const { handle } = typed(tracks);
  expect(handle()(keyEvent(" "))).toBe(false);
  expect(store.get(typeToShowInProgressAtom)).toBe(false);
});

test("clears the query and the flag after a pause", () => {
  vi.useFakeTimers();
  const { type, handle } = typed(tracks);
  type("th");
  act(() => vi.advanceTimersByTime(1000));
  expect(store.get(typeToShowInProgressAtom)).toBe(false);
  expect(handle()(keyEvent(" "))).toBe(false);
});

test("clears the flag on unmount so space is not left captured", () => {
  const { type, unmount } = typed(tracks);
  type("th");
  unmount();
  expect(store.get(typeToShowInProgressAtom)).toBe(false);
});
