import { expect, test } from "vitest";
import {
  compileNumberFilter,
  filterTracks,
  hasActiveFilters,
  searchTracks,
} from "../src/TrackFilter";
import { Track } from "../src/Library";

const columns = [
  {
    id: "name",
    type: "text" as const,
    value: (t: Track) => t.sortName || t.name,
    text: (t: Track) => t.name,
  },
  { id: "year", type: "number" as const, value: (t: Track) => t.year },
  { id: "duration", type: "number" as const, value: (t: Track) => t.duration },
];

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
    playlistIds: [],
    ...overrides,
  };
}

test("compiles comparison operators", () => {
  expect(compileNumberFilter(">2000")!(2001)).toBe(true);
  expect(compileNumberFilter(">2000")!(2000)).toBe(false);
  expect(compileNumberFilter(">=2000")!(2000)).toBe(true);
  expect(compileNumberFilter("<100")!(99)).toBe(true);
  expect(compileNumberFilter("<=100")!(100)).toBe(true);
  expect(compileNumberFilter("=5")!(5)).toBe(true);
  expect(compileNumberFilter("=5")!(6)).toBe(false);
});

test("compiles a low-high range", () => {
  const test = compileNumberFilter("1990-2000")!;
  expect(test(1989)).toBe(false);
  expect(test(1990)).toBe(true);
  expect(test(2000)).toBe(true);
  expect(test(2001)).toBe(false);
});

test("reads m:ss durations", () => {
  expect(compileNumberFilter(">3:30")!(211)).toBe(true);
  expect(compileNumberFilter(">3:30")!(209)).toBe(false);
  expect(compileNumberFilter("3:00-4:00")!(200)).toBe(true);
});

test("a bare number is an exact match", () => {
  expect(compileNumberFilter("2010")!(2010)).toBe(true);
  expect(compileNumberFilter("2010")!(2011)).toBe(false);
});

test("blank or unparseable filters compile to null", () => {
  expect(compileNumberFilter("")).toBe(null);
  expect(compileNumberFilter("   ")).toBe(null);
  expect(compileNumberFilter(">abc")).toBe(null);
  expect(compileNumberFilter("nonsense")).toBe(null);
});

test("text filters match a case-insensitive substring of the display name", () => {
  const tracks = [
    makeTrack({ id: "a", name: "Abbey Road" }),
    makeTrack({ id: "b", name: "Let It Be" }),
  ];
  expect(
    filterTracks(tracks, { name: "abbey" }, columns).map((t) => t.id)
  ).toEqual(["a"]);
});

test("number filters narrow by value", () => {
  const tracks = [
    makeTrack({ id: "a", year: 1999 }),
    makeTrack({ id: "b", year: 2005 }),
    makeTrack({ id: "c", year: 2010 }),
  ];
  expect(
    filterTracks(tracks, { year: ">=2005" }, columns).map((t) => t.id)
  ).toEqual(["b", "c"]);
});

test("multiple column filters combine with and", () => {
  const tracks = [
    makeTrack({ id: "a", name: "Come Together", year: 1969 }),
    makeTrack({ id: "b", name: "Come Away", year: 2001 }),
    makeTrack({ id: "c", name: "Something", year: 1969 }),
  ];
  expect(
    filterTracks(tracks, { name: "come", year: "<2000" }, columns).map(
      (t) => t.id
    )
  ).toEqual(["a"]);
});

test("an invalid number filter leaves the column unfiltered", () => {
  const tracks = [makeTrack({ id: "a", year: 1999 })];
  expect(filterTracks(tracks, { year: ">" }, columns)).toBe(tracks);
});

test("an all-blank state returns the tracks untouched", () => {
  const tracks = [makeTrack({ id: "a" }), makeTrack({ id: "b" })];
  expect(filterTracks(tracks, { name: "  ", year: "" }, columns)).toBe(tracks);
});

const searchColumns = [
  {
    id: "name",
    type: "text" as const,
    value: (t: Track) => t.sortName || t.name,
    text: (t: Track) => t.name,
  },
  {
    id: "artist",
    type: "text" as const,
    value: (t: Track) => t.artistSortName || t.artistName,
    text: (t: Track) => t.artistName,
  },
  { id: "genre", type: "text" as const, value: (t: Track) => t.genre },
  { id: "year", type: "number" as const, value: (t: Track) => t.year },
];

test("search matches across any text column, case-insensitively", () => {
  const tracks = [
    makeTrack({ id: "a", name: "Abbey Road", artistName: "The Beatles" }),
    makeTrack({ id: "b", name: "Thriller", artistName: "Michael Jackson" }),
    makeTrack({ id: "c", name: "Bad", genre: "Pop" }),
  ];
  expect(
    searchTracks(tracks, "beatles", searchColumns).map((t) => t.id)
  ).toEqual(["a"]);
  expect(searchTracks(tracks, "pop", searchColumns).map((t) => t.id)).toEqual([
    "c",
  ]);
});

test("search ignores number columns", () => {
  const tracks = [makeTrack({ id: "a", name: "one", year: 1999 })];
  expect(searchTracks(tracks, "1999", searchColumns)).toEqual([]);
});

test("a blank search returns the tracks untouched", () => {
  const tracks = [makeTrack({ id: "a" }), makeTrack({ id: "b" })];
  expect(searchTracks(tracks, "   ", searchColumns)).toBe(tracks);
});

test("hasActiveFilters ignores blank entries", () => {
  expect(hasActiveFilters({ name: "", year: "  " })).toBe(false);
  expect(hasActiveFilters({ name: "abba" })).toBe(true);
});
