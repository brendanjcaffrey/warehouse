import { expect, test } from "vitest";
import { Track } from "../src/Library";
import {
  changedFields,
  formFromTrack,
  hasChanges,
  isFinishValid,
  isFormValid,
  isStartValid,
  isYearValid,
  parsePlaybackTime,
  updatedTrack,
} from "../src/TrackEditForm";

function makeTrack(overrides: Partial<Track> & { id: string }): Track {
  return {
    name: "song",
    sortName: "song",
    artistName: "artist",
    artistSortName: "artist",
    albumArtistName: "album artist",
    albumArtistSortName: "album artist",
    albumName: "album",
    albumSortName: "album",
    genre: "genre",
    year: 2001,
    duration: 200,
    start: 0,
    finish: 200,
    trackNumber: 1,
    discNumber: 1,
    playCount: 7,
    rating: 60,
    musicFilename: "song.mp3",
    artworkFilename: null,
    addedDate: 0,
    playlistIds: [],
    ...overrides,
  };
}

test("parsePlaybackTime accepts m:ss.mmm and rejects out-of-range seconds", () => {
  expect(parsePlaybackTime("0:00")).toBe(0);
  expect(parsePlaybackTime("1:30")).toBe(90);
  expect(parsePlaybackTime("2:05.5")).toBeCloseTo(125.5, 5);
  expect(parsePlaybackTime("2:05.")).toBe(125);
  expect(parsePlaybackTime("1:60")).toBeNull();
  expect(parsePlaybackTime("1:5")).toBeNull();
  expect(parsePlaybackTime("nonsense")).toBeNull();
});

test("year is valid only for plain digits within int32", () => {
  const form = formFromTrack(makeTrack({ id: "a" }));
  expect(isYearValid({ ...form, year: "2001" })).toBe(true);
  expect(isYearValid({ ...form, year: "0" })).toBe(true);
  expect(isYearValid({ ...form, year: "" })).toBe(false);
  expect(isYearValid({ ...form, year: "20a1" })).toBe(false);
  expect(isYearValid({ ...form, year: "9999999999" })).toBe(false);
});

test("start and finish must parse and stay within the duration", () => {
  const track = makeTrack({ id: "a", duration: 200 });
  const form = formFromTrack(track);
  expect(isStartValid(form, track.duration)).toBe(true);
  expect(isFinishValid(form, track.duration)).toBe(true);
  expect(isStartValid({ ...form, start: "5:00" }, track.duration)).toBe(false);
  expect(isFinishValid({ ...form, finish: "3:21" }, track.duration)).toBe(
    false
  );
  expect(isFinishValid({ ...form, finish: "3:20" }, track.duration)).toBe(true);
});

test("the form is invalid when a required field is blank", () => {
  const track = makeTrack({ id: "a" });
  const form = formFromTrack(track);
  expect(isFormValid(form, track.duration)).toBe(true);
  expect(isFormValid({ ...form, name: "" }, track.duration)).toBe(false);
  expect(isFormValid({ ...form, artist: "" }, track.duration)).toBe(false);
  expect(isFormValid({ ...form, genre: "" }, track.duration)).toBe(false);
});

test("changedFields carries only edited fields, with start & finish in seconds", () => {
  const track = makeTrack({ id: "a" });
  const form = formFromTrack(track);
  expect(hasChanges(changedFields(form, track))).toBe(false);

  const edited = {
    ...form,
    name: "new name",
    year: "1999",
    start: "0:01.5",
    rating: 4.5,
  };
  const update = changedFields(edited, track);
  expect(update.has_name).toBe(true);
  expect(update.name).toBe("new name");
  expect(update.has_year).toBe(true);
  expect(update.year).toBe(1999);
  expect(update.has_start).toBe(true);
  expect(update.start).toBeCloseTo(1.5, 5);
  expect(update.has_rating).toBe(true);
  expect(update.rating).toBe(90);
  expect(update.has_artist).toBe(false);
  expect(update.has_finish).toBe(false);
});

test("updatedTrack applies edits and leaves sort names stale", () => {
  const track = makeTrack({ id: "a" });
  const form = { ...formFromTrack(track), name: "new name", rating: 2 };
  const result = updatedTrack(form, track);
  expect(result.name).toBe("new name");
  expect(result.rating).toBe(40);
  expect(result.sortName).toBe(track.sortName);
  expect(result.artistSortName).toBe(track.artistSortName);
  expect(result.playCount).toBe(track.playCount);
});
