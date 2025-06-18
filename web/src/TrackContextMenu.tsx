import { Menu, MenuItem, ListItemIcon, ListItemText } from "@mui/material";
import {
  PlayArrowRounded,
  SkipNextRounded,
  DownloadRounded,
  EditRounded,
  MoreHorizRounded,
  ArrowDropUpRounded,
  ArrowDropDownRounded,
} from "@mui/icons-material";
import { TrackAction } from "./TrackAction";
import { PlaylistEntry, PlaylistTrack } from "./Types";
import library, { Track } from "./Library";
import { useEffect, useState } from "react";
import { useAtomValue } from "jotai";
import { showTrackFnAtom } from "./State";

export interface TrackContextMenuData {
  playlistTrack: PlaylistTrack;
  track: Track;
  mouseX: number;
  mouseY: number;
}

export interface TrackContextMenuProps {
  data: TrackContextMenuData | null;
  setData: (data: TrackContextMenuData | null) => void;
  handleAction: (action: TrackAction, playlistTrack: PlaylistTrack) => void;
}

interface PlaylistEntryWithName {
  entry: PlaylistEntry;
  name: string;
}

export function TrackContextMenu({
  data,
  setData,
  handleAction,
}: TrackContextMenuProps) {
  const [playlists, setPlaylists] = useState<PlaylistEntryWithName[]>([]);
  const [showPlaylists, setShowPlaylists] = useState(false);
  const showTrackFn = useAtomValue(showTrackFnAtom);

  const handleClose = () => {
    setData(null);
    setShowPlaylists(false);
  };

  useEffect(() => {
    async function fetchPlaylistNames() {
      const playlists = await library().getPlaylistsById(
        data!.track.playlistIds
      );
      if (playlists) {
        setPlaylists(
          playlists.map((p) => {
            return {
              entry: {
                playlistId: p.id,
                playlistOffset: p.trackIds.indexOf(data!.track.id),
              },
              name: p.name,
            };
          })
        );
      }
    }
    if (data) {
      setShowPlaylists(false);
      fetchPlaylistNames();
    } else {
      setPlaylists([]);
    }
  }, [data]);

  return (
    <>
      <Menu
        open={data !== null}
        onClose={handleClose}
        anchorReference="anchorPosition"
        anchorPosition={
          data !== null ? { top: data.mouseY, left: data.mouseX } : undefined
        }
        variant="menu"
        autoFocus={false}
        slotProps={{
          list: { dense: true },
        }}
      >
        <MenuItem
          onClick={() => handleAction(TrackAction.PLAY, data!.playlistTrack)}
        >
          <ListItemIcon>
            <PlayArrowRounded fontSize="small" />
          </ListItemIcon>
          <ListItemText>Play</ListItemText>
        </MenuItem>
        <MenuItem
          onClick={() =>
            handleAction(TrackAction.PLAY_NEXT, data!.playlistTrack)
          }
        >
          <ListItemIcon>
            <SkipNextRounded fontSize="small" />
          </ListItemIcon>
          <ListItemText>Play Next</ListItemText>
        </MenuItem>
        <MenuItem
          onClick={() =>
            handleAction(TrackAction.DOWNLOAD, data!.playlistTrack)
          }
        >
          <ListItemIcon>
            <DownloadRounded fontSize="small" />
          </ListItemIcon>
          <ListItemText>Download</ListItemText>
        </MenuItem>
        {library().getTrackUserChanges() && (
          <MenuItem
            onClick={() => handleAction(TrackAction.EDIT, data!.playlistTrack)}
          >
            <ListItemIcon>
              <EditRounded fontSize="small" />
            </ListItemIcon>
            <ListItemText>Edit</ListItemText>
          </MenuItem>
        )}
        <MenuItem onClick={() => setShowPlaylists(!showPlaylists)}>
          <ListItemIcon>
            <MoreHorizRounded fontSize="small" />
          </ListItemIcon>
          <ListItemText>Show in Playlist</ListItemText>
          <ListItemIcon>
            {showPlaylists ? (
              <ArrowDropUpRounded fontSize="small" />
            ) : (
              <ArrowDropDownRounded fontSize="small" />
            )}
          </ListItemIcon>
        </MenuItem>
        {showPlaylists &&
          playlists.map((playlist) => (
            <MenuItem
              key={playlist.entry.playlistId}
              onClick={() => {
                showTrackFn.fn(playlist.entry);
                handleClose();
              }}
              disabled={
                data?.playlistTrack.playlistId === playlist.entry.playlistId
              }
            >
              <ListItemText inset>{playlist.name}</ListItemText>
            </MenuItem>
          ))}
      </Menu>
    </>
  );
}
