import { expect, test } from "vitest";
import { buildArtistList, filterArtists } from "../src/Artists";
import { Track } from "../src/Library";

function makeTrack(overrides: Partial<Track> & { id: string }): Track {
  return {
    name: overrides.id,
    sortName: "",
    artistName: "",
    artistSortName: "",
    albumArtistName: "",
    albumArtistSortName: "",
    albumName: "",
    albumSortName: "",
    genre: "",
    year: 0,
    duration: 0,
    start: 0,
    finish: 0,
    trackNumber: 0,
    discNumber: 0,
    playCount: 0,
    rating: 0,
    musicFilename: "",
    artworkFilename: null,
    addedDate: 0,
    playlistIds: [],
    ...overrides,
  };
}

test("collapses duplicate artists into a distinct list", () => {
  const artists = buildArtistList([
    makeTrack({ id: "1", artistName: "beatles" }),
    makeTrack({ id: "2", artistName: "beatles" }),
    makeTrack({ id: "3", artistName: "abba" }),
  ]);

  expect(artists.map((a) => a.name)).toEqual(["abba", "beatles"]);
});

test("sorts by sort name, falling back to the display name", () => {
  const artists = buildArtistList([
    makeTrack({
      id: "1",
      artistName: "The Beatles",
      artistSortName: "beatles",
    }),
    makeTrack({ id: "2", artistName: "abba" }),
  ]);

  expect(artists.map((a) => a.name)).toEqual(["abba", "The Beatles"]);
});

test("uses the first sort name seen for an artist", () => {
  const artists = buildArtistList([
    makeTrack({ id: "1", artistName: "queen", artistSortName: "queen" }),
    makeTrack({ id: "2", artistName: "queen", artistSortName: "zzz" }),
  ]);

  expect(artists).toEqual([{ name: "queen", sortName: "queen" }]);
});

test("skips tracks with a blank artist name", () => {
  const artists = buildArtistList([
    makeTrack({ id: "1", artistName: "" }),
    makeTrack({ id: "2", artistName: "cure" }),
  ]);

  expect(artists.map((a) => a.name)).toEqual(["cure"]);
});

const sampleArtists = [
  { name: "The Beatles", sortName: "beatles" },
  { name: "Led Zeppelin", sortName: "led zeppelin" },
  { name: "Metallica", sortName: "metallica" },
];

test("filters artists by a case-insensitive substring of the name", () => {
  expect(filterArtists(sampleArtists, "LED").map((a) => a.name)).toEqual([
    "Led Zeppelin",
  ]);
});

test("filters against the sort name too", () => {
  expect(filterArtists(sampleArtists, "beat").map((a) => a.name)).toEqual([
    "The Beatles",
  ]);
});

test("returns the whole list for a blank or whitespace query", () => {
  expect(filterArtists(sampleArtists, "")).toBe(sampleArtists);
  expect(filterArtists(sampleArtists, "   ")).toBe(sampleArtists);
});
