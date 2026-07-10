import { Playlist } from "./Library";

export interface PlaylistTreeNode {
  playlist: Playlist;
  children: PlaylistTreeNode[];
  isFolder: boolean;
}

// turns the flat list of playlists into a tree, using childPlaylistIds as the
// source of truth for parent/child relationships. the master library playlist
// is excluded since the sidebar surfaces it as the top-level "songs" entry.
export function buildPlaylistTree(playlists: Playlist[]): PlaylistTreeNode[] {
  const byId = new Map(playlists.map((p) => [p.id, p]));

  const claimedAsChild = new Set<string>();
  for (const playlist of playlists) {
    if (playlist.isLibrary) {
      continue;
    }
    for (const childId of playlist.childPlaylistIds) {
      claimedAsChild.add(childId);
    }
  }

  const sortByName = (a: PlaylistTreeNode, b: PlaylistTreeNode): number =>
    a.playlist.name.localeCompare(b.playlist.name);

  const buildNode = (
    playlist: Playlist,
    visited: Set<string>
  ): PlaylistTreeNode => {
    const children: PlaylistTreeNode[] = [];
    for (const childId of playlist.childPlaylistIds) {
      const child = byId.get(childId);
      if (!child || child.isLibrary || visited.has(child.id)) {
        continue;
      }
      children.push(buildNode(child, new Set(visited).add(child.id)));
    }
    children.sort(sortByName);
    return {
      playlist,
      children,
      isFolder: playlist.childPlaylistIds.length > 0,
    };
  };

  const roots: PlaylistTreeNode[] = [];
  for (const playlist of playlists) {
    if (playlist.isLibrary || claimedAsChild.has(playlist.id)) {
      continue;
    }
    roots.push(buildNode(playlist, new Set([playlist.id])));
  }
  roots.sort(sortByName);
  return roots;
}
