import { expect, test } from "vitest";
import { revealListSelection, trackListOwnsReveal } from "../src/Reveal";
import { RevealTarget } from "../src/State";

const artistReveal: RevealTarget = {
  trackId: "t1",
  view: "artists",
  selectionId: "Pixies",
};

test("revealListSelection returns the selection and its row index", () => {
  expect(
    revealListSelection(artistReveal, "artists", ["Blur", "Pixies", "Oasis"])
  ).toEqual({ selectionId: "Pixies", index: 1 });
});

test("revealListSelection reports index -1 when the row isn't loaded yet", () => {
  expect(revealListSelection(artistReveal, "artists", ["Blur"])).toEqual({
    selectionId: "Pixies",
    index: -1,
  });
});

test("revealListSelection ignores a reveal for another view", () => {
  expect(revealListSelection(artistReveal, "albums", ["Pixies"])).toBeNull();
});

test("revealListSelection ignores a reveal with no selection", () => {
  const noSelection: RevealTarget = { trackId: "t1", view: "artists" };
  expect(revealListSelection(noSelection, "artists", ["Pixies"])).toBeNull();
});

test("revealListSelection ignores a null reveal", () => {
  expect(revealListSelection(null, "artists", ["Pixies"])).toBeNull();
});

test("the songs view owns a go-to-song reveal", () => {
  const reveal: RevealTarget = { trackId: "t1", view: "songs" };
  expect(trackListOwnsReveal(reveal, undefined)).toBe(true);
});

test("the songs view does not own a playlist reveal", () => {
  const reveal: RevealTarget = {
    trackId: "t1",
    view: "playlist",
    selectionId: "rock",
  };
  expect(trackListOwnsReveal(reveal, undefined)).toBe(false);
});

test("a playlist owns a show-in-playlist reveal for its own id", () => {
  const reveal: RevealTarget = {
    trackId: "t1",
    view: "playlist",
    selectionId: "rock",
  };
  expect(trackListOwnsReveal(reveal, "rock")).toBe(true);
});

test("a playlist does not own a reveal for a different playlist", () => {
  const reveal: RevealTarget = {
    trackId: "t1",
    view: "playlist",
    selectionId: "jazz",
  };
  expect(trackListOwnsReveal(reveal, "rock")).toBe(false);
});

test("a playlist does not own a go-to-song reveal", () => {
  const reveal: RevealTarget = { trackId: "t1", view: "songs" };
  expect(trackListOwnsReveal(reveal, "rock")).toBe(false);
});

test("no reveal is owned by nobody", () => {
  expect(trackListOwnsReveal(null, undefined)).toBe(false);
  expect(trackListOwnsReveal(null, "rock")).toBe(false);
});
