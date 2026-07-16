import { expect, test } from "vitest";
import {
  albumKeyForTrack,
  buildAlbumList,
  filterAlbumList,
} from "../src/AlbumList";
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

test("collapses tracks into distinct albums sorted by sort name", () => {
  const albums = buildAlbumList([
    makeTrack({ id: "1", albumName: "Zebra", artistName: "a" }),
    makeTrack({ id: "2", albumName: "Zebra", artistName: "a" }),
    makeTrack({ id: "3", albumName: "Apple", artistName: "b" }),
  ]);

  expect(albums.map((a) => a.name)).toEqual(["Apple", "Zebra"]);
  expect(albums[1].tracks.map((t) => t.id)).toEqual(["1", "2"]);
});

test("skips tracks with a blank album name", () => {
  const albums = buildAlbumList([
    makeTrack({ id: "1", albumName: "", artistName: "a" }),
    makeTrack({ id: "2", albumName: "named", artistName: "a" }),
  ]);

  expect(albums.map((a) => a.name)).toEqual(["named"]);
});

test("keeps same-named albums from different artists separate", () => {
  const albums = buildAlbumList([
    makeTrack({ id: "1", albumName: "Greatest Hits", artistName: "queen" }),
    makeTrack({ id: "2", albumName: "Greatest Hits", artistName: "abba" }),
  ]);

  expect(albums).toHaveLength(2);
  expect(albums.map((a) => a.artist)).toEqual(["abba", "queen"]);
});

test("groups by the album artist, falling back to the track artist", () => {
  const albums = buildAlbumList([
    makeTrack({
      id: "1",
      albumName: "Best Of",
      artistName: "solo one",
      albumArtistName: "various",
    }),
    makeTrack({
      id: "2",
      albumName: "Best Of",
      artistName: "solo two",
      albumArtistName: "various",
    }),
  ]);

  expect(albums).toHaveLength(1);
  expect(albums[0].artist).toBe("various");
  expect(albums[0].tracks.map((t) => t.id)).toEqual(["1", "2"]);
});

test("sorts by the album sort name when present", () => {
  const albums = buildAlbumList([
    makeTrack({
      id: "1",
      albumName: "The Wall",
      albumSortName: "wall",
      artistName: "a",
    }),
    makeTrack({ id: "2", albumName: "Abbey Road", artistName: "b" }),
  ]);

  expect(albums.map((a) => a.name)).toEqual(["Abbey Road", "The Wall"]);
});

test("picks a track with artwork for the cover", () => {
  const albums = buildAlbumList([
    makeTrack({ id: "1", albumName: "a", artistName: "x" }),
    makeTrack({
      id: "2",
      albumName: "a",
      artistName: "x",
      artworkFilename: "cover.jpg",
    }),
  ]);

  expect(albums[0].artworkTrack.id).toBe("2");
});

const sampleAlbums = buildAlbumList([
  makeTrack({ id: "1", albumName: "Abbey Road", artistName: "The Beatles" }),
  makeTrack({ id: "2", albumName: "Nevermind", artistName: "Nirvana" }),
]);

test("filters albums by a case-insensitive substring of the album name", () => {
  expect(filterAlbumList(sampleAlbums, "ABBEY").map((a) => a.name)).toEqual([
    "Abbey Road",
  ]);
});

test("filters albums by the artist name too", () => {
  expect(filterAlbumList(sampleAlbums, "nirvana").map((a) => a.name)).toEqual([
    "Nevermind",
  ]);
});

test("returns the whole list for a blank or whitespace query", () => {
  expect(filterAlbumList(sampleAlbums, "")).toBe(sampleAlbums);
  expect(filterAlbumList(sampleAlbums, "   ")).toBe(sampleAlbums);
});

test("albumKeyForTrack matches the key an album entry is built with", () => {
  const track = makeTrack({
    id: "1",
    albumName: "Best Of",
    artistName: "solo",
    albumArtistName: "various",
  });
  const albums = buildAlbumList([track]);
  expect(albumKeyForTrack(track)).toBe(albums[0].key);
});

test("albumKeyForTrack falls back to the track artist without an album artist", () => {
  const track = makeTrack({ id: "1", albumName: "Solo", artistName: "singer" });
  expect(albumKeyForTrack(track)).toBe("singer\tSolo");
});
