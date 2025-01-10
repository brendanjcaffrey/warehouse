import "fake-indexeddb/auto";
import { Track } from "../src/Library";
import { FilterTrackList } from "../src/TrackTableFilter";
import { expect, test } from "vitest";

const TRACKS: Track[] = [
  {
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
    artworks: [],
  },
];

test("checks all words against name case insensitive", async () => {
  const trackIndexes = [0];
  expect(FilterTrackList(TRACKS, trackIndexes, "wake")).toEqual([0]);
  expect(FilterTrackList(TRACKS, trackIndexes, "Me")).toEqual([0]);
  expect(FilterTrackList(TRACKS, trackIndexes, "UP")).toEqual([0]);
  expect(FilterTrackList(TRACKS, trackIndexes, "zzz")).toEqual([]);
  expect(FilterTrackList(TRACKS, trackIndexes, "me wake")).toEqual([0]);
  expect(FilterTrackList(TRACKS, trackIndexes, "me wake zzz")).toEqual([]);
});

test("checks all words against artist case insensitive", async () => {
  const trackIndexes = [0];
  expect(FilterTrackList(TRACKS, trackIndexes, "avicii")).toEqual([0]);
  expect(FilterTrackList(TRACKS, trackIndexes, "AVICII")).toEqual([0]);
  expect(FilterTrackList(TRACKS, trackIndexes, "avicii zzz")).toEqual([]);
});

test("checks all words against album case insensitive", async () => {
  const trackIndexes = [0];
  expect(FilterTrackList(TRACKS, trackIndexes, "true")).toEqual([0]);
  expect(FilterTrackList(TRACKS, trackIndexes, "TRUE")).toEqual([0]);
  expect(FilterTrackList(TRACKS, trackIndexes, "true zzz")).toEqual([]);
});

test("checks all words against genre case insensitive", async () => {
  const trackIndexes = [0];
  expect(FilterTrackList(TRACKS, trackIndexes, "house")).toEqual([0]);
  expect(FilterTrackList(TRACKS, trackIndexes, "HOUSE")).toEqual([0]);
  expect(FilterTrackList(TRACKS, trackIndexes, "house zzz")).toEqual([]);
});

test("checks against name, artist, album and genre in the same search", async () => {
  const trackIndexes = [0];
  expect(
    FilterTrackList(TRACKS, trackIndexes, "avicii wake true house")
  ).toEqual([0]);
});
