import { GridChildComponentProps } from "react-window";
import { useTheme, Theme } from "@mui/material";
import { VolumeUpRounded } from "@mui/icons-material";
import { Track } from "./Library";
import { COLUMNS } from "./TrackTableColumns";
import { TrackAction } from "./TrackAction";
import { CELL_HORIZONTAL_PADDING_SIDE } from "./TrackTableConstants";
import { PlaylistEntry, PlaylistTrack } from "./Types";

function CellBackgroundColor(
  rowIndex: number,
  isSelected: boolean,
  theme: Theme
) {
  if (isSelected) {
    return theme.palette.mode === "dark"
      ? theme.palette.action.selected
      : theme.palette.action.focus;
  } else {
    return rowIndex % 2 === 0
      ? theme.palette.action.hover
      : theme.palette.background.default;
  }
}

interface TrackTableCellProps extends GridChildComponentProps {
  playlistId: string;
  tracks: Track[];
  trackDisplayIndexes: number[];
  selectedPlaylistEntry: PlaylistEntry | undefined;
  setSelectedPlaylistOffset: (playlistOffset: number) => void;
  playingPlaylistEntry: PlaylistEntry | undefined;
  showContextMenu: (
    event: React.MouseEvent<HTMLDivElement>,
    playlistTrack: PlaylistTrack
  ) => void;
  handleAction: (action: TrackAction, playlistTrack: PlaylistTrack) => void;
}

export function TrackTableCell(props: TrackTableCellProps) {
  const theme = useTheme();

  const rowIndex = props.rowIndex;
  const playlistOffset = props.trackDisplayIndexes[rowIndex];
  const trackId = props.tracks[playlistOffset].id;
  const column = COLUMNS[props.columnIndex];
  const playlistTrack = {
    playlistId: props.playlistId,
    trackId,
    playlistOffset,
  };
  const isSelected =
    props.playlistId === props.selectedPlaylistEntry?.playlistId &&
    playlistOffset === props.selectedPlaylistEntry.playlistOffset;
  const IsPlaying =
    props.playlistId === props.playingPlaylistEntry?.playlistId &&
    playlistOffset === props.playingPlaylistEntry.playlistOffset;

  return (
    <div
      style={{
        color: theme.palette.text.primary,
        backgroundColor: CellBackgroundColor(rowIndex, isSelected, theme),
        padding: `0 ${CELL_HORIZONTAL_PADDING_SIDE}px`,
        boxSizing: "border-box",
        whiteSpace: "nowrap",
        overflow: "hidden",
        textOverflow: "ellipsis",
        ...props.style,
      }}
      className="valign-center no-select"
      onClick={() =>
        !isSelected && props.setSelectedPlaylistOffset(playlistOffset)
      }
      onContextMenu={(event) => props.showContextMenu(event, playlistTrack)}
      onDoubleClick={() => props.handleAction(TrackAction.PLAY, playlistTrack)}
    >
      {column.canHaveNowPlayingIcon && IsPlaying ? (
        <VolumeUpRounded fontSize="small" color="primary" />
      ) : null}
      {column.render(props.tracks[props.trackDisplayIndexes[rowIndex]])}
    </div>
  );
}
