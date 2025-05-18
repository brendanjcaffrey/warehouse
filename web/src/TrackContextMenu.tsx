import { Menu, MenuItem, ListItemIcon, ListItemText } from "@mui/material";
import {
  PlayArrowRounded,
  SkipNextRounded,
  DownloadRounded,
  EditRounded,
} from "@mui/icons-material";
import { TrackAction } from "./TrackAction";
import { PlaylistTrack } from "./Types";

export interface TrackContextMenuData {
  playlistTrack: PlaylistTrack;
  mouseX: number;
  mouseY: number;
}

export interface TrackContextMenuProps {
  data: TrackContextMenuData | null;
  setData: (data: TrackContextMenuData | null) => void;
  handleAction: (action: TrackAction, playlistTrack: PlaylistTrack) => void;
}

export function TrackContextMenu({
  data,
  setData,
  handleAction,
}: TrackContextMenuProps) {
  const handleClose = () => {
    setData(null);
  };

  return (
    <Menu
      open={data !== null}
      onClose={handleClose}
      anchorReference="anchorPosition"
      anchorPosition={
        data !== null ? { top: data.mouseY, left: data.mouseX } : undefined
      }
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
        onClick={() => handleAction(TrackAction.PLAY_NEXT, data!.playlistTrack)}
      >
        <ListItemIcon>
          <SkipNextRounded fontSize="small" />
        </ListItemIcon>
        <ListItemText>Play Next</ListItemText>
      </MenuItem>
      <MenuItem
        onClick={() => handleAction(TrackAction.DOWNLOAD, data!.playlistTrack)}
      >
        <ListItemIcon>
          <DownloadRounded fontSize="small" />
        </ListItemIcon>
        <ListItemText>Download</ListItemText>
      </MenuItem>
      <MenuItem
        onClick={() => handleAction(TrackAction.EDIT, data!.playlistTrack)}
      >
        <ListItemIcon>
          <EditRounded fontSize="small" />
        </ListItemIcon>
        <ListItemText>Edit</ListItemText>
      </MenuItem>
    </Menu>
  );
}
