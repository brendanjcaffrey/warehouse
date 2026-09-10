import { expect, test } from "vitest";
import {
  TRACK_COLUMNS,
  formatDateAdded,
  formatDateAddedShort,
} from "../src/TrackColumns";
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
    addedDate: 0,
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

test("the added column sorts on its raw epoch seconds", () => {
  expect(column("added").value(makeTrack({ addedDate: 1783082096 }))).toBe(
    1783082096
  );
  expect(column("added").defaultDirection).toBe("desc");
  expect(column("added").filterable).toBe(false);
});

// built from local-time components so the expectation holds in any timezone
function localEpoch(
  year: number,
  monthIndex: number,
  day: number,
  hours = 12,
  minutes = 0
): number {
  return new Date(year, monthIndex, day, hours, minutes).getTime() / 1000;
}

function mediumDate(epoch: number): string {
  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium" }).format(
    new Date(epoch * 1000)
  );
}

test("added renders as m/d/yyyy and blank when missing", () => {
  const epoch = localEpoch(2026, 8, 10);
  expect(column("added").render(makeTrack({ addedDate: epoch }))).toBe(
    "9/10/2026"
  );
  expect(column("added").render(makeTrack({ addedDate: 0 }))).toBe("");
});

test("formatDateAddedShort uses m/d/yyyy without zero padding", () => {
  expect(formatDateAddedShort(localEpoch(2026, 6, 3))).toBe("7/3/2026");
  expect(formatDateAddedShort(localEpoch(2025, 11, 25))).toBe("12/25/2025");
  expect(formatDateAddedShort(0)).toBe("");
});

test("formatDateAdded renders a medium date with hh:mm a", () => {
  const afternoon = localEpoch(2026, 6, 3, 15, 4);
  expect(formatDateAdded(afternoon)).toBe(`${mediumDate(afternoon)} 03:04 PM`);
  const morning = localEpoch(2026, 6, 3, 9, 30);
  expect(formatDateAdded(morning)).toBe(`${mediumDate(morning)} 09:30 AM`);
});

test("formatDateAdded maps midnight and noon to 12", () => {
  const midnight = localEpoch(2026, 6, 3, 0, 0);
  expect(formatDateAdded(midnight)).toBe(`${mediumDate(midnight)} 12:00 AM`);
  const noon = localEpoch(2026, 6, 3, 12, 0);
  expect(formatDateAdded(noon)).toBe(`${mediumDate(noon)} 12:00 PM`);
});

test("formatDateAdded blanks the epoch-0 sentinel", () => {
  expect(formatDateAdded(0)).toBe("");
});
