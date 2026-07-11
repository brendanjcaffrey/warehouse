import { expect, test } from "vitest";
import { TRACK_COLUMNS } from "../src/TrackColumns";
import { Track } from "../src/Library";

function makeTrack(overrides: Partial<Track>): Track {
  return {
    id: "t1",
    name: "The Track",
    sortName: "track, the",
    artistName: "The Artist",
    artistSortName: "artist, the",
    albumArtistName: "The Artist",
    albumArtistSortName: "artist, the",
    albumName: "The Album",
    albumSortName: "album, the",
    genre: "rock",
    year: 1999,
    duration: 185,
    start: 0,
    finish: 185,
    trackNumber: 1,
    discNumber: 1,
    playCount: 7,
    rating: 80,
    musicFilename: "song.mp3",
    artworkFilename: null,
    playlistIds: [],
    ...overrides,
  };
}

function column(id: string) {
  const found = TRACK_COLUMNS.find((c) => c.id === id);
  if (!found) {
    throw new Error(`no column ${id}`);
  }
  return found;
}

test("text columns sort on their sort-name variant", () => {
  const track = makeTrack({});
  expect(column("name").value(track)).toBe("track, the");
  expect(column("artist").value(track)).toBe("artist, the");
  expect(column("album").value(track)).toBe("album, the");
  expect(column("genre").value(track)).toBe("rock");
});

test("text columns fall back to the display name when the sort name is blank", () => {
  const track = makeTrack({
    name: "Beatles",
    sortName: "",
    artistName: "Beatles",
    artistSortName: "",
    albumName: "Abbey Road",
    albumSortName: "",
  });
  expect(column("name").value(track)).toBe("Beatles");
  expect(column("artist").value(track)).toBe("Beatles");
  expect(column("album").value(track)).toBe("Abbey Road");
});

test("numeric columns expose their raw number for comparison", () => {
  const track = makeTrack({
    year: 1999,
    duration: 185,
    rating: 80,
    playCount: 7,
  });
  expect(column("year").value(track)).toBe(1999);
  expect(column("duration").value(track)).toBe(185);
  expect(column("rating").value(track)).toBe(80);
  expect(column("plays").value(track)).toBe(7);
});

test("empty numeric fields render blank rather than zero", () => {
  const track = makeTrack({ year: 0, playCount: 0 });
  expect(column("year").render(track)).toBe("");
  expect(column("plays").render(track)).toBe("");
});

test("duration renders as a minutes:seconds string", () => {
  expect(column("duration").render(makeTrack({ duration: 185 }))).toBe("3:05");
});
