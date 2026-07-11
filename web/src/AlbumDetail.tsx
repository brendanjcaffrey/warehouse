import { useMemo, useRef } from "react";
import { Track } from "./Library";
import { buildAlbums } from "./Albums";
import { AlbumSection } from "./AlbumSection";
import { useTrackListNav } from "./useTrackListNav";
import { useAlbumArtworkRequests } from "./useAlbumArtworkRequests";
import { useTrackContextMenu } from "./TrackContextMenu";
import { FileRequestSource } from "./WorkerTypes";

interface AlbumDetailProps {
  name: string;
  tracks: Track[];
}

function AlbumDetail({ name, tracks }: AlbumDetailProps) {
  // the tracks are all one album, so this yields a single section reusing the
  // same layout as the artist view
  const albums = useMemo(() => buildAlbums(tracks), [tracks]);
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

export default AlbumDetail;
