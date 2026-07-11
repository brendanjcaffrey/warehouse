import { expect, test } from "vitest";
import { resolvePlayingSource } from "../src/PlayingSource";
import { Playlist, Track } from "../src/Library";

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

const track = makeTrack({
  id: "t1",
  artistName: "Pixies",
  albumName: "Doolittle",
});

test("resolves the library source to the songs view", () => {
  expect(resolvePlayingSource("library", track, [])).toEqual({
    reveal: { trackId: "t1", view: "songs" },
    path: "/songs",
    label: "Songs",
  });
});

test("resolves an artist source to the artists view selecting that artist", () => {
  expect(resolvePlayingSource("artist:Pixies", track, [])).toEqual({
    reveal: { trackId: "t1", view: "artists", selectionId: "Pixies" },
    path: "/artists",
    label: "Pixies",
  });
});

test("resolves an album source to the albums view selecting the track's album", () => {
  expect(resolvePlayingSource("album:Doolittle", track, [])).toEqual({
    reveal: {
      trackId: "t1",
      view: "albums",
      selectionId: "Pixies\tDoolittle",
    },
    path: "/albums",
    label: "Doolittle",
  });
});

test("resolves a playlist id to that playlist by name", () => {
  const playlists = [makePlaylist({ id: "rock", name: "Rock" })];
  expect(resolvePlayingSource("rock", track, playlists)).toEqual({
    reveal: { trackId: "t1", view: "playlist", selectionId: "rock" },
    path: "/playlists/rock",
    label: "Rock",
  });
});

test("yields null for an unknown playlist id", () => {
  expect(resolvePlayingSource("gone", track, [])).toBeNull();
});
