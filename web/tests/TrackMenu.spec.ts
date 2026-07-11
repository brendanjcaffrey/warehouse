import { expect, test } from "vitest";
import { trackPlaylistOptions } from "../src/TrackMenu";
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
