import { expect, test } from "vitest";
import { cycleSort, sortTracks, SortKey } from "../src/TrackSort";
import { Track } from "../src/Library";

const columns = [
  { id: "name", type: "text" as const, value: (t: Track) => t.sortName },
  {
    id: "artist",
    type: "text" as const,
    value: (t: Track) => t.artistSortName,
  },
  { id: "year", type: "number" as const, value: (t: Track) => t.year },
];

function makeTrack(overrides: Partial<Track> & { id: string }): Track {
  return {
    name: overrides.id,
    sortName: overrides.id,
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

test("a plain click cycles a single column asc, desc, then unsorted", () => {
  let keys: SortKey[] = [];
  keys = cycleSort(keys, "name", false);
  expect(keys).toEqual([{ columnId: "name", direction: "asc" }]);
  keys = cycleSort(keys, "name", false);
  expect(keys).toEqual([{ columnId: "name", direction: "desc" }]);
  keys = cycleSort(keys, "name", false);
  expect(keys).toEqual([]);
});

test("a plain click on another column replaces the whole sort", () => {
  const keys = cycleSort(
    [{ columnId: "name", direction: "desc" }],
    "year",
    false
  );
  expect(keys).toEqual([{ columnId: "year", direction: "asc" }]);
});

test("a plain click collapses a multi-column sort back to one column", () => {
  const keys = cycleSort(
    [
      { columnId: "name", direction: "asc" },
      { columnId: "artist", direction: "asc" },
    ],
    "name",
    false
  );
  expect(keys).toEqual([{ columnId: "name", direction: "asc" }]);
});

test("a shift click appends a column then cycles just that one", () => {
  let keys: SortKey[] = [{ columnId: "name", direction: "asc" }];
  keys = cycleSort(keys, "artist", true);
  expect(keys).toEqual([
    { columnId: "name", direction: "asc" },
    { columnId: "artist", direction: "asc" },
  ]);
  keys = cycleSort(keys, "artist", true);
  expect(keys).toEqual([
    { columnId: "name", direction: "asc" },
    { columnId: "artist", direction: "desc" },
  ]);
  keys = cycleSort(keys, "artist", true);
  expect(keys).toEqual([{ columnId: "name", direction: "asc" }]);
});

test("an empty sort leaves the tracks in their original order", () => {
  const tracks = [makeTrack({ id: "c" }), makeTrack({ id: "a" })];
  expect(sortTracks(tracks, [], columns)).toBe(tracks);
});

test("sorts by a numeric column in both directions", () => {
  const tracks = [
    makeTrack({ id: "a", year: 2001 }),
    makeTrack({ id: "b", year: 1999 }),
    makeTrack({ id: "c", year: 2010 }),
  ];
  expect(
    sortTracks(tracks, [{ columnId: "year", direction: "asc" }], columns).map(
      (t) => t.id
    )
  ).toEqual(["b", "a", "c"]);
  expect(
    sortTracks(tracks, [{ columnId: "year", direction: "desc" }], columns).map(
      (t) => t.id
    )
  ).toEqual(["c", "a", "b"]);
});

test("breaks ties with the next sort key", () => {
  const tracks = [
    makeTrack({ id: "a", artistSortName: "same", sortName: "second" }),
    makeTrack({ id: "b", artistSortName: "same", sortName: "first" }),
    makeTrack({ id: "c", artistSortName: "other", sortName: "third" }),
  ];
  const keys: SortKey[] = [
    { columnId: "artist", direction: "asc" },
    { columnId: "name", direction: "asc" },
  ];
  expect(sortTracks(tracks, keys, columns).map((t) => t.id)).toEqual([
    "c",
    "b",
    "a",
  ]);
});

test("keeps the incoming order for rows equal on every key", () => {
  const tracks = [
    makeTrack({ id: "a", year: 2000 }),
    makeTrack({ id: "b", year: 2000 }),
  ];
  expect(
    sortTracks(tracks, [{ columnId: "year", direction: "asc" }], columns).map(
      (t) => t.id
    )
  ).toEqual(["a", "b"]);
});
