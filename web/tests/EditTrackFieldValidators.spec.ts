import { expect, test } from "vitest";
import {
  ValidOptionalField,
  ValidRequiredField,
  ValidYear,
  ValidPlaybackPosition,
} from "../src/EditTrackFieldValidators";
import { Track } from "../src/Library";

const TRACK: Track = {
  id: "00B94C30DA792045",
  name: "Wake Me Up",
  sortName: "",
  artistName: "Avicii",
  artistSortName: "",
  albumArtistName: "",
  albumArtistSortName: "",
  albumName: "True",
  albumSortName: "",
  genre: "House",
  year: 2013,
  duration: 249,
  start: 0,
  finish: 249,
  trackNumber: 0,
  discNumber: 0,
  playCount: 50,
  rating: 100,
  ext: "mp3",
  fileMd5: "md5",
  artwork: null,
  playlistIds: [],
};

test("ValidOptionalField", () => {
  expect(ValidOptionalField("", TRACK)).toBe(true);
  expect(ValidOptionalField("a", TRACK)).toBe(true);
});

test("ValidRequiredField", () => {
  expect(ValidRequiredField("", TRACK)).toBe(false);
  expect(ValidRequiredField("a", TRACK)).toBe(true);
});

test("ValidYear", () => {
  expect(ValidYear("", TRACK)).toBe(false);
  expect(ValidYear("a", TRACK)).toBe(false);
  expect(ValidYear("a1", TRACK)).toBe(false);
  expect(ValidYear("1a", TRACK)).toBe(false);
  expect(ValidYear("1", TRACK)).toBe(true);
  expect(ValidYear("-1", TRACK)).toBe(false);
  expect(ValidYear("2025", TRACK)).toBe(true);
});

test("ValidPlaybackPosition", () => {
  expect(ValidPlaybackPosition("", TRACK)).toBe(false);
  expect(ValidPlaybackPosition("1", TRACK)).toBe(false);
  expect(ValidPlaybackPosition("1:", TRACK)).toBe(false);
  expect(ValidPlaybackPosition("1:0", TRACK)).toBe(false);
  expect(ValidPlaybackPosition("1:00", TRACK)).toBe(true);
  expect(ValidPlaybackPosition("1:000", TRACK)).toBe(false);
  expect(ValidPlaybackPosition("1:30", TRACK)).toBe(true);
  expect(ValidPlaybackPosition("1:59", TRACK)).toBe(true);
  expect(ValidPlaybackPosition("1:60", TRACK)).toBe(false);
  expect(ValidPlaybackPosition("1:300", TRACK)).toBe(false);
  expect(ValidPlaybackPosition("1:30.", TRACK)).toBe(true);
  expect(ValidPlaybackPosition("1:30.0", TRACK)).toBe(true);
  expect(ValidPlaybackPosition("1:30.1", TRACK)).toBe(true);
  expect(ValidPlaybackPosition("1:30.12", TRACK)).toBe(true);
  expect(ValidPlaybackPosition("1:30.123", TRACK)).toBe(true);
  expect(ValidPlaybackPosition("1:30.1234", TRACK)).toBe(false);

  expect(ValidPlaybackPosition("4:08.999", TRACK)).toBe(true);
  expect(ValidPlaybackPosition("4:09", TRACK)).toBe(true);
  // greater than the duration
  expect(ValidPlaybackPosition("4:09.001", TRACK)).toBe(false);
});
