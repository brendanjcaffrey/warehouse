import { Menu, MenuItem, ListItemIcon, ListItemText } from "@mui/material";
import {
  PlayArrowRounded,
  SkipNextRounded,
  DownloadRounded,
  EditRounded,
} from "@mui/icons-material";
import { TrackAction } from "./TrackAction";

export interface TrackContextMenuData {
  trackId: string;
  mouseX: number;
  mouseY: number;
}

export interface TrackContextMenuProps {
  data: TrackContextMenuData | null;
  setData: (data: TrackContextMenuData | null) => void;
  handleAction: (action: TrackAction, trackId: string | undefined) => void;
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
      <MenuItem onClick={() => handleAction(TrackAction.PLAY, data?.trackId)}>
        <ListItemIcon>
          <PlayArrowRounded fontSize="small" />
        </ListItemIcon>
        <ListItemText>Play</ListItemText>
      </MenuItem>
      <MenuItem
        onClick={() => handleAction(TrackAction.PLAY_NEXT, data?.trackId)}
      >
        <ListItemIcon>
          <SkipNextRounded fontSize="small" />
        </ListItemIcon>
        <ListItemText>Play Next</ListItemText>
      </MenuItem>
      <MenuItem
        onClick={() => handleAction(TrackAction.DOWNLOAD, data?.trackId)}
      >
        <ListItemIcon>
          <DownloadRounded fontSize="small" />
        </ListItemIcon>
        <ListItemText>Download</ListItemText>
      </MenuItem>
      <MenuItem onClick={() => handleAction(TrackAction.EDIT, data?.trackId)}>
        <ListItemIcon>
          <EditRounded fontSize="small" />
        </ListItemIcon>
        <ListItemText>Edit</ListItemText>
      </MenuItem>
    </Menu>
  );
}
