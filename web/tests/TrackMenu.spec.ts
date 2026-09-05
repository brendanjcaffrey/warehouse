import { expect, test } from "vitest";
import {
  downloadFilename,
  menuPosition,
  submenuPlacement,
  trackGotoTargets,
  trackPlaylistOptions,
} from "../src/TrackMenu";
import { Playlist } from "../src/Library";

function makePlaylist(
  overrides: Partial<Playlist> & { id: string; name: string }
): Playlist {
  return {
    parentId: "",
    isLibrary: false,
    trackIds: [],
    parentPlaylistIds: [],
    childPlaylistIds: [],
    ...overrides,
  };
}

const playlists = [
  makePlaylist({ id: "lib", name: "Library", isLibrary: true }),
  makePlaylist({ id: "rock", name: "Rock" }),
  makePlaylist({ id: "chill", name: "Chill" }),
  makePlaylist({ id: "party", name: "Party" }),
];

test("resolves a track's playlist ids to names, sorted", () => {
  const track = { playlistIds: ["party", "rock", "chill"] };
  expect(trackPlaylistOptions(track, playlists).map((o) => o.name)).toEqual([
    "Chill",
    "Party",
    "Rock",
  ]);
});

test("excludes the current playlist", () => {
  const track = { playlistIds: ["rock", "chill"] };
  expect(
    trackPlaylistOptions(track, playlists, "rock").map((o) => o.id)
  ).toEqual(["chill"]);
});

test("drops the library playlist and unknown ids", () => {
  const track = { playlistIds: ["lib", "rock", "gone"] };
  expect(trackPlaylistOptions(track, playlists).map((o) => o.id)).toEqual([
    "rock",
  ]);
});

test("a track in no playlists yields no options", () => {
  expect(trackPlaylistOptions({ playlistIds: [] }, playlists)).toEqual([]);
});

const track = {
  artistName: "Pixies",
  albumName: "Doolittle",
  albumArtistName: "",
};

test("offers all three go-to entries from a playlist view", () => {
  const targets = trackGotoTargets(track, "/playlists/abc");
  expect(targets.map((t) => t.kind)).toEqual(["song", "artist", "album"]);
  const artist = targets.find((t) => t.kind === "artist");
  expect(artist).toMatchObject({
    view: "artists",
    path: "/artists",
    selectionId: "Pixies",
  });
  const album = targets.find((t) => t.kind === "album");
  expect(album).toMatchObject({
    view: "albums",
    path: "/albums",
    selectionId: "Pixies\tDoolittle",
  });
});

test("drops the entry for the view we're already in", () => {
  expect(trackGotoTargets(track, "/songs").map((t) => t.kind)).toEqual([
    "artist",
    "album",
  ]);
  expect(trackGotoTargets(track, "/artists").map((t) => t.kind)).toEqual([
    "song",
    "album",
  ]);
  expect(trackGotoTargets(track, "/albums").map((t) => t.kind)).toEqual([
    "song",
    "artist",
  ]);
});

test("drops artist and album entries when the track has neither", () => {
  const bare = { artistName: "", albumName: "", albumArtistName: "" };
  expect(trackGotoTargets(bare, "/playlists/abc").map((t) => t.kind)).toEqual([
    "song",
  ]);
});

test("builds a download filename as 'artist - name' with the source extension", () => {
  expect(
    downloadFilename({
      artistName: "Radiohead",
      name: "Idioteque",
      musicFilename: "abc123.m4a",
    })
  ).toBe("Radiohead - Idioteque.m4a");
});

test("keeps only the final extension when the filename has several dots", () => {
  expect(
    downloadFilename({
      artistName: "Boards of Canada",
      name: "Roygbiv",
      musicFilename: "track.2.flac",
    })
  ).toBe("Boards of Canada - Roygbiv.flac");
});

test("omits the extension when the source filename has none", () => {
  expect(
    downloadFilename({
      artistName: "Aphex Twin",
      name: "Xtal",
      musicFilename: "noextension",
    })
  ).toBe("Aphex Twin - Xtal");
});

const viewport = { width: 1000, height: 800 };
const menuSize = { width: 200, height: 300 };

test("opens the menu at the click point when it fits", () => {
  expect(menuPosition({ x: 100, y: 100 }, menuSize, viewport)).toEqual({
    x: 100,
    y: 100,
    maxHeight: undefined,
  });
});

test("flips the menu above the click point near the bottom edge", () => {
  expect(menuPosition({ x: 100, y: 760 }, menuSize, viewport)).toMatchObject({
    x: 100,
    y: 460,
  });
});

test("flips the menu left of the click point near the right edge", () => {
  expect(menuPosition({ x: 950, y: 100 }, menuSize, viewport)).toMatchObject({
    x: 750,
    y: 100,
  });
});

test("clamps the menu when it fits on neither side of the click", () => {
  expect(
    menuPosition({ x: 100, y: 250 }, menuSize, { width: 1000, height: 400 })
  ).toMatchObject({ y: 92 });
});

test("keeps a menu taller than the viewport on screen and scrollable", () => {
  expect(
    menuPosition(
      { x: 100, y: 100 },
      { width: 200, height: 500 },
      {
        width: 1000,
        height: 400,
      }
    )
  ).toEqual({ x: 100, y: 8, maxHeight: 384 });
});

const anchor = { left: 300, right: 500, top: 400, bottom: 440 };

test("flies the submenu out to the right and down when there's room", () => {
  expect(
    submenuPlacement(anchor, { width: 180, height: 300 }, viewport)
  ).toEqual({ left: false, up: false });
});

test("flips the submenu left when it would run off the right edge", () => {
  const atRight = { left: 700, right: 900, top: 400, bottom: 440 };
  expect(
    submenuPlacement(atRight, { width: 180, height: 300 }, viewport)
  ).toEqual({ left: true, up: false });
});

test("aligns the submenu upwards when it would run off the bottom", () => {
  expect(
    submenuPlacement(anchor, { width: 180, height: 420 }, viewport)
  ).toEqual({ left: false, up: true });
});

test("leaves the submenu where it is when neither side has room", () => {
  const cramped = { left: 20, right: 220, top: 20, bottom: 60 };
  expect(
    submenuPlacement(cramped, { width: 900, height: 780 }, viewport)
  ).toEqual({ left: false, up: false });
});
