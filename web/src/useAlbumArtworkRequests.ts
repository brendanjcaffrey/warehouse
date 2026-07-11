import { useEffect } from "react";
import { Track } from "./Library";
import { DownloadWorker } from "./DownloadWorker";
import {
  FileType,
  FileRequestSource,
  SetSourceRequestedFilesMessage,
  TrackFileIds,
  SET_SOURCE_REQUESTED_FILES_TYPE,
} from "./WorkerTypes";

// asks the download worker to fetch the covers for the given items under a
// browse source, and drops the request when the items change or the view
// unmounts so it stops downloading them
export function useAlbumArtworkRequests(
  items: { artworkTrack: Track }[],
  source: FileRequestSource
) {
  useEffect(() => {
    const seen = new Set<string>();
    const ids: TrackFileIds[] = [];
    for (const { artworkTrack } of items) {
      const fileId = artworkTrack.artworkFilename;
      if (fileId && !seen.has(fileId)) {
        seen.add(fileId);
        ids.push({ trackId: artworkTrack.id, fileId });
      }
    }

    const request = (ids: TrackFileIds[]) =>
      DownloadWorker.postMessage({
        type: SET_SOURCE_REQUESTED_FILES_TYPE,
        source,
        fileType: FileType.ARTWORK,
        ids,
      } as SetSourceRequestedFilesMessage);

    request(ids);
    return () => request([]);
  }, [items, source]);
}
