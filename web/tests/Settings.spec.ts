import { beforeEach, expect, test } from "vitest";
import { stringSetStorage, ClampSidebarWidth } from "../src/Settings";

const KEY = "openedFolders";

beforeEach(() => {
  localStorage.clear();
});

test("round trips a set of strings through storage", () => {
  const original = new Set(["a", "b", "c"]);
  stringSetStorage.setItem(KEY, original);
  expect(localStorage.getItem(KEY)).toBe(JSON.stringify(["a", "b", "c"]));
  const restored = stringSetStorage.getItem(KEY, new Set());
  expect(restored).toEqual(original);
});

test("round trips an empty set without producing a phantom entry", () => {
  stringSetStorage.setItem(KEY, new Set());
  const restored = stringSetStorage.getItem(KEY, new Set(["fallback"]));
  expect(restored.size).toBe(0);
});

test("falls back to the initial value when nothing is stored", () => {
  const initial = new Set(["x"]);
  expect(stringSetStorage.getItem(KEY, initial)).toBe(initial);
});

test("falls back to the initial value on malformed json", () => {
  localStorage.setItem(KEY, "not,json");
  const initial = new Set(["x"]);
  expect(stringSetStorage.getItem(KEY, initial)).toBe(initial);
});

test("removes the stored value", () => {
  stringSetStorage.setItem(KEY, new Set(["a"]));
  stringSetStorage.removeItem(KEY);
  expect(localStorage.getItem(KEY)).toBeNull();
});

test("clamps sidebar width to the allowed range", () => {
  expect(ClampSidebarWidth(0)).toBe(180);
  expect(ClampSidebarWidth(9999)).toBe(480);
  expect(ClampSidebarWidth(300)).toBe(300);
});
