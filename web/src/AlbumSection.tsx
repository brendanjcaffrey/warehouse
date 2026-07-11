import { Fragment } from "react";
import { PlayFill, Shuffle, MusicNoteBeamed } from "react-bootstrap-icons";
import { Track } from "./Library";
import { Album, formatAlbumSummary } from "./Albums";
import { useArtworkFileURL } from "./useArtworkFileURL";
import { FormatPlaybackPosition } from "./PlaybackPositionFormatters";
import { TrackMenuActions } from "./TrackContextMenu";
import { player } from "./Player";
import IconButton from "./IconButton";
import TrackRating from "./TrackRating";

export const ARTWORK_SIZE = 160;

// a track in an album plays within that album, starting at itself, matching
// the album detail view on ios
export function playTrackInAlbum(album: Album, track: Track) {
  player().playTracks(
    `album:${album.name}`,
    album.tracks,
    album.tracks.indexOf(track)
  );
}

// play and shuffle icons for a scope (an album, or a whole artist); the caller
// wires each to play or shuffle its tracks
export function PlayShuffleButtons({
  size,
  onPlay,
  onShuffle,
}: {
  size: number;
  onPlay: () => void;
  onShuffle: () => void;
}) {
  return (
    <span className="d-inline-flex gap-1">
      <IconButton aria-label="play" onClick={onPlay}>
        <PlayFill size={size} />
      </IconButton>
      <IconButton aria-label="shuffle" onClick={onShuffle}>
        <Shuffle size={size} />
      </IconButton>
    </span>
  );
}

export function AlbumArtwork({
  track,
  size = ARTWORK_SIZE,
}: {
  track: Track;
  size?: number;
}) {
  const url = useArtworkFileURL(track);
  if (url) {
    return (
      <img
        src={url}
        alt=""
        width={size}
        height={size}
        className="rounded shadow-sm flex-shrink-0"
        style={{ objectFit: "cover" }}
      />
    );
  }
  return (
    <div
      className="rounded bg-body-secondary d-flex align-items-center justify-content-center flex-shrink-0"
      style={{ width: size, height: size }}
    >
      <MusicNoteBeamed size={Math.round(size / 4)} className="text-secondary" />
    </div>
  );
}

// what a parent view (artist or album detail) supplies: the selection and the
// context-menu opener. the per-track play handlers are derived from the album
// inside AlbumSection, so a track plays within its own album
export interface TrackListProps {
  selectedTrackId: string | null;
  onSelect: (id: string) => void;
  onTrackContextMenu: (
    event: React.MouseEvent,
    track: Track,
    actions: TrackMenuActions
  ) => void;
}

interface TrackRowsProps extends TrackListProps {
  tracks: Track[];
  onPlayTrack: (track: Track) => void;
  onPlayTrackNext: (track: Track) => void;
}

function TrackRows({
  tracks,
  selectedTrackId,
  onSelect,
  onPlayTrack,
  onPlayTrackNext,
  onTrackContextMenu,
}: TrackRowsProps) {
  return (
    <>
      {tracks.map((track) => (
        <tr
          key={track.id}
          data-track-id={track.id}
          role="option"
          aria-selected={track.id === selectedTrackId}
          onClick={() => onSelect(track.id)}
          onDoubleClick={() => onPlayTrack(track)}
          onContextMenu={(event) => {
            onSelect(track.id);
            onTrackContextMenu(event, track, {
              play: () => onPlayTrack(track),
              playNext: () => onPlayTrackNext(track),
            });
          }}
          className={track.id === selectedTrackId ? "table-active" : ""}
          style={{ cursor: "pointer" }}
        >
          <td>{track.name}</td>
          <td className="text-end text-nowrap" style={{ width: 1 }}>
            <TrackRating track={track} />
          </td>
          <td
            className="text-end text-secondary text-nowrap"
            style={{ width: 1 }}
          >
            {FormatPlaybackPosition(track.duration)}
          </td>
        </tr>
      ))}
    </>
  );
}

export function AlbumSection({
  album,
  selectedTrackId,
  onSelect,
  onTrackContextMenu,
}: { album: Album } & TrackListProps) {
  const subheaderParts = [
    album.genre,
    album.year > 0 ? String(album.year) : "",
  ].filter(Boolean);

  const source = `album:${album.name}`;
  const playTrack = (track: Track) => playTrackInAlbum(album, track);
  const playTrackNext = (track: Track) => player().playTrackNext(source, track);
  const rowProps = {
    selectedTrackId,
    onSelect,
    onPlayTrack: playTrack,
    onPlayTrackNext: playTrackNext,
    onTrackContextMenu,
  };

  return (
    <div className="d-flex gap-4 mb-5">
      <div
        className="flex-shrink-0 text-center"
        style={{ width: ARTWORK_SIZE }}
      >
        <AlbumArtwork track={album.artworkTrack} />
        <div className="text-secondary small mt-2">
          {formatAlbumSummary(album.songCount, album.totalDuration)}
        </div>
      </div>
      <div className="flex-grow-1" style={{ minWidth: 0 }}>
        <div className="d-flex align-items-center gap-2 mb-1">
          <h4 className="mb-0 text-truncate">
            {album.isUnknown ? "Unknown Album" : album.name}
          </h4>
          <PlayShuffleButtons
            size={18}
            onPlay={() => player().playTracksInOrder(source, album.tracks, 0)}
            onShuffle={() => player().playTracksShuffled(source, album.tracks)}
          />
        </div>
        {subheaderParts.length > 0 && (
          <div className="text-secondary mb-2">
            {subheaderParts.join(" · ")}
          </div>
        )}
        <table className="table table-sm align-middle mb-0">
          <tbody>
            {album.hasMultipleDiscs ? (
              album.discs.map((disc) => (
                <Fragment key={disc.discNumber}>
                  <tr>
                    <td
                      colSpan={3}
                      className="text-secondary small fw-semibold border-0 pt-3"
                    >
                      disc {disc.discNumber}
                    </td>
                  </tr>
                  <TrackRows tracks={disc.tracks} {...rowProps} />
                </Fragment>
              ))
            ) : (
              <TrackRows tracks={album.tracks} {...rowProps} />
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
