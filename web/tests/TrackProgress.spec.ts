import { describe, it, expect } from "vitest";
import { trackProgress } from "../src/TrackProgress";

describe("trackProgress", () => {
  it("returns zeros and no notches without a track", () => {
    expect(trackProgress(undefined)).toEqual({
      duration: 0,
      start: 0,
      finish: 0,
      startNotch: null,
      finishNotch: null,
    });
  });

  it("falls back to duration when finish is unset", () => {
    const p = trackProgress({ duration: 200, start: 0, finish: 0 });
    expect(p.finish).toBe(200);
    expect(p.finishNotch).toBeNull();
  });

  it("shows both notches at fractional positions when trimmed", () => {
    const p = trackProgress({ duration: 200, start: 50, finish: 150 });
    expect(p.startNotch).toBe(0.25);
    expect(p.finishNotch).toBe(0.75);
  });

  it("hides the start notch within a second of the real start", () => {
    expect(
      trackProgress({ duration: 200, start: 0.5, finish: 200 }).startNotch
    ).toBeNull();
    expect(
      trackProgress({ duration: 200, start: 1, finish: 200 }).startNotch
    ).toBeNull();
    expect(
      trackProgress({ duration: 200, start: 1.5, finish: 200 }).startNotch
    ).not.toBeNull();
  });

  it("hides the finish notch within a second of the real finish", () => {
    expect(
      trackProgress({ duration: 200, start: 0, finish: 199.5 }).finishNotch
    ).toBeNull();
    expect(
      trackProgress({ duration: 200, start: 0, finish: 199 }).finishNotch
    ).toBeNull();
    expect(
      trackProgress({ duration: 200, start: 0, finish: 198.5 }).finishNotch
    ).not.toBeNull();
  });
});
