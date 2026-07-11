import { expect, test } from "vitest";
import { trackGotoTargets, trackPlaylistOptions } from "../src/TrackMenu";
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
