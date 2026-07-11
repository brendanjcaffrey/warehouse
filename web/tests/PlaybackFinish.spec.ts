import { expect, test } from "vitest";
import { trackFinish, shouldSkipAtFinish } from "../src/PlaybackFinish";

test("trackFinish uses the trim finish when set", () => {
  expect(trackFinish({ finish: 180, duration: 200 })).toBe(180);
});

test("trackFinish falls back to the duration when the finish is unset", () => {
  expect(trackFinish({ finish: 0, duration: 200 })).toBe(200);
});

test("shouldSkipAtFinish advances once past the start and at the finish", () => {
  expect(shouldSkipAtFinish(180, 0, 180, false)).toBe(true);
});

test("shouldSkipAtFinish waits before the finish", () => {
  expect(shouldSkipAtFinish(179, 0, 180, false)).toBe(false);
});

test("shouldSkipAtFinish ignores a timeupdate still at the start", () => {
  expect(shouldSkipAtFinish(5, 5, 5, false)).toBe(false);
});

test("shouldSkipAtFinish lets a track seeked past its finish play out", () => {
  expect(shouldSkipAtFinish(190, 0, 180, true)).toBe(false);
});
