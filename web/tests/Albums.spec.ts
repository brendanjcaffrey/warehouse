import { expect, test } from "vitest";
import { buildAlbums, formatAlbumSummary } from "../src/Albums";
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
    playlistIds: [],
    ...overrides,
  };
}

test("groups tracks into albums newest year first", () => {
  const albums = buildAlbums([
    makeTrack({ id: "1", albumName: "old", year: 2000 }),
    makeTrack({ id: "2", albumName: "new", year: 2020 }),
    makeTrack({ id: "3", albumName: "mid", year: 2010 }),
  ]);

  expect(albums.map((a) => a.name)).toEqual(["new", "mid", "old"]);
});

test("pins the blank-named album to the bottom as unknown", () => {
  const albums = buildAlbums([
    makeTrack({ id: "1", albumName: "", year: 2020 }),
    makeTrack({ id: "2", albumName: "named", year: 1990 }),
  ]);

  expect(albums.map((a) => a.name)).toEqual(["named", ""]);
  expect(albums[1].isUnknown).toBe(true);
});

test("takes the album year and genre from its tracks", () => {
  const albums = buildAlbums([
    makeTrack({ id: "1", albumName: "a", year: 0, genre: "" }),
    makeTrack({ id: "2", albumName: "a", year: 1999, genre: "rock" }),
  ]);

  expect(albums[0].year).toBe(1999);
  expect(albums[0].genre).toBe("rock");
});

test("sorts tracks by disc then track number", () => {
  const albums = buildAlbums([
    makeTrack({ id: "d2t1", albumName: "a", discNumber: 2, trackNumber: 1 }),
    makeTrack({ id: "d1t2", albumName: "a", discNumber: 1, trackNumber: 2 }),
    makeTrack({ id: "d1t1", albumName: "a", discNumber: 1, trackNumber: 1 }),
  ]);

  expect(albums[0].tracks.map((t) => t.id)).toEqual(["d1t1", "d1t2", "d2t1"]);
});

test("splits into disc sections only when there are multiple discs", () => {
  const single = buildAlbums([
    makeTrack({ id: "1", albumName: "a", discNumber: 1 }),
    makeTrack({ id: "2", albumName: "a", discNumber: 1 }),
  ]);
  expect(single[0].hasMultipleDiscs).toBe(false);
  expect(single[0].discs).toHaveLength(1);

  const multi = buildAlbums([
    makeTrack({ id: "1", albumName: "a", discNumber: 1 }),
    makeTrack({ id: "2", albumName: "a", discNumber: 2 }),
  ]);
  expect(multi[0].hasMultipleDiscs).toBe(true);
  expect(multi[0].discs.map((d) => d.discNumber)).toEqual([1, 2]);
});

test("picks a track with artwork for the cover", () => {
  const albums = buildAlbums([
    makeTrack({
      id: "1",
      albumName: "a",
      trackNumber: 1,
      artworkFilename: null,
    }),
    makeTrack({
      id: "2",
      albumName: "a",
      trackNumber: 2,
      artworkFilename: "cover.jpg",
    }),
  ]);

  expect(albums[0].artworkTrack.id).toBe("2");
});

test("summarizes song count and rounded minutes with pluralization", () => {
  expect(formatAlbumSummary(1, 60)).toBe("1 song, 1 minute");
  expect(formatAlbumSummary(12, 2010)).toBe("12 songs, 34 minutes");
  expect(formatAlbumSummary(0, 0)).toBe("0 songs, 0 minutes");
});
