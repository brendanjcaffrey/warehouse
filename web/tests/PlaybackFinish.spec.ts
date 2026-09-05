import { expect, test } from "vitest";
import {
  trackFinish,
  shouldSkipAtFinish,
  shouldFinishAtEnded,
  audioSettledOnTrack,
  AudioFinishState,
} from "../src/PlaybackFinish";

const settledAudio: AudioFinishState = {
  srcTrackId: "a",
  seeking: false,
  readyState: HTMLMediaElement.HAVE_ENOUGH_DATA,
  ended: true,
};

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

test("audioSettledOnTrack accepts a loaded, settled source", () => {
  expect(audioSettledOnTrack(settledAudio, "a")).toBe(true);
});

test("audioSettledOnTrack rejects a source from another track", () => {
  expect(audioSettledOnTrack(settledAudio, "b")).toBe(false);
});

test("audioSettledOnTrack rejects a mid-seek element", () => {
  expect(audioSettledOnTrack({ ...settledAudio, seeking: true }, "a")).toBe(
    false
  );
});

test("audioSettledOnTrack rejects an element still loading", () => {
  const loading = {
    ...settledAudio,
    readyState: HTMLMediaElement.HAVE_NOTHING,
  };
  expect(audioSettledOnTrack(loading, "a")).toBe(false);
});

test("shouldFinishAtEnded finishes a track that played to its end", () => {
  expect(shouldFinishAtEnded(settledAudio, "a")).toBe(true);
});

test("shouldFinishAtEnded ignores an ended event for the previous track", () => {
  // the previous track ended, but the next one is already playing
  expect(shouldFinishAtEnded(settledAudio, "b")).toBe(false);
});

test("shouldFinishAtEnded ignores an ended event while the next track loads", () => {
  // the src has been swapped, so the element is back to loading and not ended
  const loading = {
    ...settledAudio,
    srcTrackId: "b",
    readyState: HTMLMediaElement.HAVE_NOTHING,
    ended: false,
  };
  expect(shouldFinishAtEnded(loading, "b")).toBe(false);
});

test("shouldFinishAtEnded ignores a settled element that is not ended", () => {
  expect(shouldFinishAtEnded({ ...settledAudio, ended: false }, "a")).toBe(
    false
  );
});
