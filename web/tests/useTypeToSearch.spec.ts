import { expect, test } from "vitest";
import { isQueryKey, nearestMatch } from "../src/useTypeToSearch";

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
