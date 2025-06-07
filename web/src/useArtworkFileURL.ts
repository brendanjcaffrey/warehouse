import { useState, useEffect, useCallback } from "react";
import { files } from "./Files";
import { FileType, IsTypedMessage, IsFileFetchedMessage } from "./WorkerTypes";
import { Track } from "./Library";
import { DownloadWorker } from "./DownloadWorkerHandle";

export function useArtworkFileURL(track: Track | undefined) {
  const [shownArtwork, setShownArtwork] = useState<string | null>(null);
  const [artworkFileURL, setArtworkFileURL] = useState<string | null>(null);

  const showFetchedArtwork = useCallback(
    async (artworkId: string) => {
      const url = await files().tryGetFileURL(FileType.ARTWORK, artworkId);
      if (url) {
        setArtworkFileURL(url);
      } else {
        // nop, parent handles downloading artwork, so wait for a message to come in from the worker
      }
    },
    [setArtworkFileURL]
  );

  const handleDownloadWorkerMessage = useCallback(
    (m: MessageEvent) => {
      const { data } = m;
      if (!IsTypedMessage(data)) {
        return;
      }
      if (
        IsFileFetchedMessage(data) &&
        data.fileType === FileType.ARTWORK &&
        data.ids.fileId === track?.artwork
      ) {
        showFetchedArtwork(data.ids.fileId);
      }
    },
    [track, showFetchedArtwork]
  );

  useEffect(() => {
    DownloadWorker.addEventListener("message", handleDownloadWorkerMessage);
    return () => {
      DownloadWorker.removeEventListener(
        "message",
        handleDownloadWorkerMessage
      );
    };
  }, [handleDownloadWorkerMessage]);

  useEffect(() => {
    if (track && track.artwork !== shownArtwork) {
      if (artworkFileURL) {
        URL.revokeObjectURL(artworkFileURL);
        setArtworkFileURL(null);
      }

      const artworkId = track.artwork;
      if (artworkId) {
        setShownArtwork(artworkId);
        showFetchedArtwork(artworkId);
      } else {
        setShownArtwork(null);
      }
    }
  }, [track, artworkFileURL, shownArtwork, showFetchedArtwork]);

  return artworkFileURL;
}
