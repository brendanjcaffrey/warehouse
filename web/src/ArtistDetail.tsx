import { useMemo, useRef } from "react";
import { Track } from "./Library";
import { buildAlbums } from "./Albums";
import { AlbumSection, PlayShuffleButtons } from "./AlbumSection";
import { useTrackListNav } from "./useTrackListNav";
import { useAlbumArtworkRequests } from "./useAlbumArtworkRequests";
import { useTrackContextMenu } from "./TrackContextMenu";
import { FileRequestSource } from "./WorkerTypes";

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
  const containerRef = useRef<HTMLDivElement>(null);
  const { selectedTrackId, setSelectedTrackId, handleKeyDown } =
    useTrackListNav(flatTracks, containerRef);
  const trackMenu = useTrackContextMenu();

  useAlbumArtworkRequests(albums, FileRequestSource.ARTWORK_BROWSE);

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
          onTrackContextMenu={trackMenu.openMenu}
        />
      ))}
      {trackMenu.element}
    </div>
  );
}

export default ArtistDetail;
