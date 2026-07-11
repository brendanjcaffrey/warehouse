import { expect, test } from "vitest";
import { nearestMatch } from "../src/useTypeToSearch";

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
