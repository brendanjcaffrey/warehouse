import { Playlist } from "./Library";

export interface PlaylistTreeNode {
  playlist: Playlist;
  children: PlaylistTreeNode[];
  isFolder: boolean;
}

// turns the flat list of playlists into a tree. parentId is the source of truth
// for direct parent/child links; childPlaylistIds is flattened to every
// descendant, so using it here would show a nested playlist under both its
// parent and its grandparent. the master library playlist is excluded since the
// sidebar surfaces it as the top-level "songs" entry.
export function buildPlaylistTree(playlists: Playlist[]): PlaylistTreeNode[] {
  const byId = new Map(playlists.map((p) => [p.id, p]));

  const directChildren = new Map<string, Playlist[]>();
  for (const playlist of playlists) {
    if (playlist.isLibrary) {
      continue;
    }
    const siblings = directChildren.get(playlist.parentId);
    if (siblings) {
      siblings.push(playlist);
    } else {
      directChildren.set(playlist.parentId, [playlist]);
    }
  }

  const sortByName = (a: PlaylistTreeNode, b: PlaylistTreeNode): number =>
    a.playlist.name.localeCompare(b.playlist.name);

  const buildNode = (
    playlist: Playlist,
    visited: Set<string>
  ): PlaylistTreeNode => {
    const children: PlaylistTreeNode[] = [];
    for (const child of directChildren.get(playlist.id) ?? []) {
      if (visited.has(child.id)) {
        continue;
      }
      children.push(buildNode(child, new Set(visited).add(child.id)));
    }
    children.sort(sortByName);
    return {
      playlist,
      children,
      isFolder: children.length > 0,
    };
  };

  const roots: PlaylistTreeNode[] = [];
  for (const playlist of playlists) {
    if (playlist.isLibrary) {
      continue;
    }
    const parent = byId.get(playlist.parentId);
    if (parent && !parent.isLibrary) {
      continue;
    }
    roots.push(buildNode(playlist, new Set([playlist.id])));
  }
  roots.sort(sortByName);
  return roots;
}
