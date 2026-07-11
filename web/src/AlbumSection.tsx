import { Fragment } from "react";
import { PlayFill, Shuffle, MusicNoteBeamed } from "react-bootstrap-icons";
import { Track } from "./Library";
import { Album, formatAlbumSummary } from "./Albums";
import { useArtworkFileURL } from "./useArtworkFileURL";
import { FormatPlaybackPosition } from "./PlaybackPositionFormatters";
import IconButton from "./IconButton";
import StarRating from "./StarRating";

export const ARTWORK_SIZE = 160;

// play and shuffle icons; they do nothing for now
export function PlayShuffleButtons({ size }: { size: number }) {
  return (
    <span className="d-inline-flex gap-1">
      <IconButton aria-label="play">
        <PlayFill size={size} />
      </IconButton>
      <IconButton aria-label="shuffle">
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

export interface TrackListProps {
  selectedTrackId: string | null;
  onSelect: (id: string) => void;
}

function TrackRows({
  tracks,
  selectedTrackId,
  onSelect,
}: { tracks: Track[] } & TrackListProps) {
  return (
    <>
      {tracks.map((track) => (
        <tr
          key={track.id}
          data-track-id={track.id}
          role="option"
          aria-selected={track.id === selectedTrackId}
          onClick={() => onSelect(track.id)}
          className={track.id === selectedTrackId ? "table-active" : ""}
          style={{ cursor: "pointer" }}
        >
          <td>{track.name}</td>
          <td className="text-end text-nowrap" style={{ width: 1 }}>
            <StarRating rating={track.rating} />
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
}: { album: Album } & TrackListProps) {
  const subheaderParts = [
    album.genre,
    album.year > 0 ? String(album.year) : "",
  ].filter(Boolean);

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
          <PlayShuffleButtons size={18} />
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
                  <TrackRows
                    tracks={disc.tracks}
                    selectedTrackId={selectedTrackId}
                    onSelect={onSelect}
                  />
                </Fragment>
              ))
            ) : (
              <TrackRows
                tracks={album.tracks}
                selectedTrackId={selectedTrackId}
                onSelect={onSelect}
              />
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
