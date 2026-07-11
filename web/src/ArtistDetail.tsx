import {
  Fragment,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { PlayFill, Shuffle, MusicNoteBeamed } from "react-bootstrap-icons";
import { Track } from "./Library";
import { Album, buildAlbums, formatAlbumSummary } from "./Albums";
import { useArtworkFileURL } from "./useArtworkFileURL";
import { useTypeToSearch } from "./useTypeToSearch";
import { FormatPlaybackPosition } from "./PlaybackPositionFormatters";
import { DownloadWorker } from "./DownloadWorker";
import {
  FileType,
  FileRequestSource,
  SetSourceRequestedFilesMessage,
  TrackFileIds,
  SET_SOURCE_REQUESTED_FILES_TYPE,
} from "./WorkerTypes";
import IconButton from "./IconButton";
import StarRating from "./StarRating";

const ARTWORK_SIZE = 160;

// play and shuffle icons; they do nothing for now
function PlayShuffleButtons({ size }: { size: number }) {
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

function AlbumArtwork({ track }: { track: Track }) {
  const url = useArtworkFileURL(track);
  if (url) {
    return (
      <img
        src={url}
        alt=""
        width={ARTWORK_SIZE}
        height={ARTWORK_SIZE}
        className="rounded shadow-sm"
        style={{ objectFit: "cover" }}
      />
    );
  }
  return (
    <div
      className="rounded bg-body-secondary d-flex align-items-center justify-content-center"
      style={{ width: ARTWORK_SIZE, height: ARTWORK_SIZE }}
    >
      <MusicNoteBeamed size={40} className="text-secondary" />
    </div>
  );
}

interface TrackListProps {
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

function AlbumSection({
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

interface ArtistDetailProps {
  name: string;
  tracks: Track[];
}

function ArtistDetail({ name, tracks }: ArtistDetailProps) {
  const albums = useMemo(() => buildAlbums(tracks), [tracks]);
  // one ordered list across every album so the arrow keys walk the whole artist
  const flatTracks = useMemo(
    () => albums.flatMap((album) => album.tracks),
    [albums]
  );
  const [selectedTrackId, setSelectedTrackId] = useState<string | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);

  const selectIndex = useCallback(
    (index: number) => {
      const track = flatTracks[index];
      if (!track) {
        return;
      }
      setSelectedTrackId(track.id);
      containerRef.current
        ?.querySelector(`[data-track-id="${CSS.escape(track.id)}"]`)
        ?.scrollIntoView({ block: "nearest" });
    },
    [flatTracks]
  );

  const searchNames = useMemo(
    () => flatTracks.map((track) => track.name),
    [flatTracks]
  );
  const handleTypeSearch = useTypeToSearch(searchNames, selectIndex);

  const handleKeyDown = useCallback(
    (event: React.KeyboardEvent) => {
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        const current = flatTracks.findIndex(
          (track) => track.id === selectedTrackId
        );
        const delta = event.key === "ArrowDown" ? 1 : -1;
        selectIndex(current === -1 ? 0 : current + delta);
        return;
      }
      if (handleTypeSearch(event)) {
        event.preventDefault();
      }
    },
    [flatTracks, selectedTrackId, selectIndex, handleTypeSearch]
  );

  // ask the download worker to fetch the covers for the albums on screen, and
  // drop the request when we navigate away so it stops downloading them
  useEffect(() => {
    const seen = new Set<string>();
    const ids: TrackFileIds[] = [];
    for (const { artworkTrack } of albums) {
      const fileId = artworkTrack.artworkFilename;
      if (fileId && !seen.has(fileId)) {
        seen.add(fileId);
        ids.push({ trackId: artworkTrack.id, fileId });
      }
    }

    const request = (ids: TrackFileIds[]) =>
      DownloadWorker.postMessage({
        type: SET_SOURCE_REQUESTED_FILES_TYPE,
        source: FileRequestSource.ARTWORK_BROWSE,
        fileType: FileType.ARTWORK,
        ids,
      } as SetSourceRequestedFilesMessage);

    request(ids);
    return () => request([]);
  }, [albums]);

  return (
    <div
      ref={containerRef}
      className="h-100 overflow-auto p-4"
      role="listbox"
      aria-label={`${name} tracks`}
      tabIndex={0}
      onKeyDown={handleKeyDown}
    >
      <div className="d-flex align-items-center gap-3 mb-4">
        <h2 className="mb-0 text-truncate">{name}</h2>
        <PlayShuffleButtons size={22} />
      </div>
      {albums.map((album) => (
        <AlbumSection
          key={album.name || "unknown"}
          album={album}
          selectedTrackId={selectedTrackId}
          onSelect={setSelectedTrackId}
        />
      ))}
    </div>
  );
}

export default ArtistDetail;
