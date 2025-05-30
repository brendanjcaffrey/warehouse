import { GridChildComponentProps } from "react-window";
import { VolumeUpRounded } from "@mui/icons-material";
import { Track } from "./Library";
import { COLUMNS } from "./TrackTableColumns";
import { TrackAction } from "./TrackAction";
import { lightestGrey, selectedGrey, white } from "./Colors";
import { CELL_HORIZONTAL_PADDING_SIDE } from "./TrackTableConstants";
import { PlaylistEntry, PlaylistTrack } from "./Types";

function CellBackgroundColor(rowIndex: number, isSelected: boolean) {
  if (isSelected) {
    return selectedGrey;
  } else {
    return rowIndex % 2 === 0 ? lightestGrey : white;
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
        backgroundColor: CellBackgroundColor(rowIndex, isSelected),
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
