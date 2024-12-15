import { useState, useEffect } from "react";
import { useAtom, useSetAtom } from "jotai";
import {
  List,
  ListItem,
  ListItemButton,
  ListItemText,
  ListItemIcon,
  IconButton,
  Collapse,
} from "@mui/material";
import {
  LibraryMusicRounded,
  FolderRounded,
  ListRounded,
  ExpandLess,
  ExpandMore,
} from "@mui/icons-material";
import library from "./Library";
import { openedFoldersAtom } from "./Settings";
import { selectedPlaylistAtom } from "./State";

const ICON_WIDTH = 30;

interface PlaylistDisplay {
  id: string;
  name: string;
  isLibrary: boolean;
  parentId: string;
  children: PlaylistDisplay[];
}

function ComparePlaylists(a: PlaylistDisplay, b: PlaylistDisplay) {
  // library playlist first
  if (a.isLibrary && !b.isLibrary) return -1;
  if (!a.isLibrary && b.isLibrary) return 1;

  // folders next
  if (a.children.length > 0 && b.children.length === 0) return -1;
  if (a.children.length === 0 && b.children.length > 0) return 1;

  // finally, sort by name
  return a.name.localeCompare(b.name);
}

function SortPlaylistTree(list: PlaylistDisplay[]) {
  list.sort(ComparePlaylists);
  for (const playlist of list) {
    SortPlaylistTree(playlist.children);
  }
}

function PlaylistItem({ playlist }: { playlist: PlaylistDisplay }) {
  const [openedFolders, setOpenedFolders] = useAtom(openedFoldersAtom);
  const [selectedPlaylist, setSelectedPlaylist] = useAtom(selectedPlaylistAtom);

  const isOpen = openedFolders.has(playlist.id);
  const isFolder = playlist.children.length > 0;

  const getIcon = () => {
    if (playlist.isLibrary) {
      return <LibraryMusicRounded />;
    } else if (isFolder) {
      return <FolderRounded />;
    } else {
      return <ListRounded />;
    }
  };

  const toggleOpen = () => {
    const newSet = new Set(openedFolders);
    if (isOpen) {
      newSet.delete(playlist.id);
    } else {
      newSet.add(playlist.id);
    }
    setOpenedFolders(newSet);
  };

  const getSecondaryAction = () => {
    if (isFolder) {
      return (
        <IconButton onClick={toggleOpen} edge="end">
          {isOpen ? <ExpandLess /> : <ExpandMore />}
        </IconButton>
      );
    } else {
      return null;
    }
  };

  const selectPlaylist = () => {
    setSelectedPlaylist(playlist.id);
  };

  return (
    <>
      <ListItem
        key={playlist.id}
        secondaryAction={getSecondaryAction()}
        disablePadding
      >
        <ListItemButton
          selected={playlist.id === selectedPlaylist}
          onClick={selectPlaylist}
        >
          <ListItemIcon sx={{ minWidth: `${ICON_WIDTH}px` }}>
            {getIcon()}
          </ListItemIcon>
          <ListItemText primary={playlist.name} />
        </ListItemButton>
      </ListItem>
      {isFolder && (
        <Collapse in={isOpen} timeout="auto" unmountOnExit>
          <PlaylistLevelList playlists={playlist.children} inSublist={true} />
        </Collapse>
      )}
    </>
  );
}

function PlaylistLevelList({
  playlists,
  inSublist,
}: {
  playlists: PlaylistDisplay[];
  inSublist: boolean;
}) {
  return (
    <List dense sx={{ pl: `${inSublist ? ICON_WIDTH : 0}px`, py: 0 }}>
      {playlists.map((playlist) => (
        <PlaylistItem key={playlist.id} playlist={playlist} />
      ))}
    </List>
  );
}

function Playlists() {
  const setSelectedPlaylist = useSetAtom(selectedPlaylistAtom);
  const [playlists, setPlaylists] = useState<PlaylistDisplay[]>([]);

  useEffect(() => {
    async function fetchPlaylists() {
      const allPlaylists = await library().getAllPlaylists();
      if (!allPlaylists) {
        return;
      }

      const display = [];
      const playlistsMap = new Map<string, PlaylistDisplay>();
      for (const playlist of allPlaylists) {
        playlistsMap.set(playlist.id, {
          id: playlist.id,
          name: playlist.name,
          isLibrary: playlist.isLibrary,
          parentId: playlist.parentId,
          children: [],
        });
      }

      for (const playlist of playlistsMap.values()) {
        const parent = playlistsMap.get(playlist.parentId);
        if (parent) {
          parent.children.push(playlist);
        } else {
          display.push(playlist);
        }
      }

      SortPlaylistTree(display);
      setPlaylists(display);
      if (display.length > 0) {
        setSelectedPlaylist(display[0].id);
      }
    }

    fetchPlaylists();
  }, [setPlaylists, setSelectedPlaylist]);

  return <PlaylistLevelList playlists={playlists} />;
}

export default Playlists;
