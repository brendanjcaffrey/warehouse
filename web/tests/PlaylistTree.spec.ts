import { expect, test } from "vitest";
import { buildPlaylistTree } from "../src/PlaylistTree";
import { Playlist } from "../src/Library";

function makePlaylist(overrides: Partial<Playlist> & { id: string }): Playlist {
  return {
    name: overrides.id,
    parentId: "",
    isLibrary: false,
    trackIds: [],
    parentPlaylistIds: [],
    childPlaylistIds: [],
    ...overrides,
  };
}

test("excludes the library playlist from the roots", () => {
  const tree = buildPlaylistTree([
    makePlaylist({ id: "lib", name: "Library", isLibrary: true }),
    makePlaylist({ id: "a", name: "alpha" }),
  ]);

  expect(tree.map((n) => n.playlist.id)).toEqual(["a"]);
});

test("sorts roots and children by name", () => {
  const tree = buildPlaylistTree([
    makePlaylist({ id: "b", name: "beta" }),
    makePlaylist({ id: "a", name: "alpha" }),
    makePlaylist({ id: "folder", name: "stuff", childPlaylistIds: ["y", "x"] }),
    makePlaylist({ id: "y", name: "yankee" }),
    makePlaylist({ id: "x", name: "xray" }),
  ]);

  expect(tree.map((n) => n.playlist.name)).toEqual(["alpha", "beta", "stuff"]);
  const folder = tree.find((n) => n.playlist.id === "folder")!;
  expect(folder.isFolder).toBe(true);
  expect(folder.children.map((n) => n.playlist.name)).toEqual([
    "xray",
    "yankee",
  ]);
});

test("nests folders and keeps children out of the roots", () => {
  const tree = buildPlaylistTree([
    makePlaylist({ id: "top", name: "top", childPlaylistIds: ["mid"] }),
    makePlaylist({ id: "mid", name: "mid", childPlaylistIds: ["leaf"] }),
    makePlaylist({ id: "leaf", name: "leaf" }),
  ]);

  expect(tree.map((n) => n.playlist.id)).toEqual(["top"]);
  const mid = tree[0].children[0];
  expect(mid.playlist.id).toBe("mid");
  expect(mid.isFolder).toBe(true);
  expect(mid.children[0].playlist.id).toBe("leaf");
  expect(mid.children[0].isFolder).toBe(false);
});

test("marks empty playlists as non-folders", () => {
  const tree = buildPlaylistTree([makePlaylist({ id: "a", name: "alpha" })]);
  expect(tree[0].isFolder).toBe(false);
});

test("does not loop forever on a cyclic reference", () => {
  const tree = buildPlaylistTree([
    makePlaylist({ id: "a", name: "a", childPlaylistIds: ["b"] }),
    makePlaylist({ id: "b", name: "b", childPlaylistIds: ["a"] }),
  ]);

  // both reference each other, so neither is a root; nothing is emitted
  expect(tree).toEqual([]);
});
