import { useState, useEffect, useCallback } from "react";
import { useAtomValue } from "jotai";
import { Box, CircularProgress } from "@mui/material";
import DelayedElement from "./DelayedElement";
import { showArtworkAtom } from "./Settings";
import { playingTrackAtom } from "./State";
import { DownloadWorker } from "./DownloadWorkerHandle";
import { isTypedMessage, isArtworkFetchedMessage } from "./WorkerTypes";

const ARTWORK_SIZE = "40px";
const SPINNER_SIZE = "20px";
const SPACING = "4px";

function Artwork() {
  const showArtwork = useAtomValue(showArtworkAtom);
  const playingTrack = useAtomValue(playingTrackAtom);
  const [shownArtwork, setShownArtwork] = useState<string | null>(null);
  const [artworkFileURL, setArtworkFileURL] = useState<string | null>(null);
  const [artworkDirHandle, setArtworkDirHandle] =
    useState<FileSystemDirectoryHandle | null>(null);

  async function getArtworkDirHandle() {
    try {
      const mainDir = await navigator.storage.getDirectory();
      const artworkDirHandle = await mainDir.getDirectoryHandle("artwork", {
        create: true,
      });
      setArtworkDirHandle(artworkDirHandle);
    } catch (e) {
      console.error("unable to get artwork dir handle", e);
    }
  }

  useEffect(() => {
    getArtworkDirHandle();
  }, []);

  const showFetchedArtwork = useCallback(
    async (artworkFilename: string) => {
      try {
        const fileHandle = await artworkDirHandle?.getFileHandle(
          artworkFilename
        );
        if (!fileHandle) {
          console.error("getFileHandle returned null");
          return;
        }

        const file = await fileHandle.getFile();
        setArtworkFileURL(URL.createObjectURL(file));
      } catch {
        // nop, Player handles downloading artwork, so wait for a message to come in from the worker
      }
    },
    [artworkDirHandle, setArtworkFileURL]
  );

  const handleDownloadWorkerMessage = useCallback(
    (m: MessageEvent) => {
      const { data } = m;
      if (!isTypedMessage(data)) {
        return;
      }
      if (
        isArtworkFetchedMessage(data) &&
        data.artworkFilename === playingTrack?.artworks[0]
      ) {
        showFetchedArtwork(data.artworkFilename);
      }
    },
    [playingTrack, showFetchedArtwork]
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
    if (
      playingTrack &&
      artworkDirHandle &&
      playingTrack.artworks[0] !== shownArtwork
    ) {
      if (artworkFileURL) {
        URL.revokeObjectURL(artworkFileURL);
        setArtworkFileURL(null);
      }

      const artworkFilename = playingTrack.artworks[0];
      if (artworkFilename) {
        setShownArtwork(artworkFilename);
        showFetchedArtwork(artworkFilename);
      } else {
        setShownArtwork(null);
      }
    }
  }, [
    playingTrack,
    artworkFileURL,
    shownArtwork,
    artworkDirHandle,
    showFetchedArtwork,
  ]);

  if (showArtwork && (playingTrack?.artworks.length ?? 0) > 0) {
    return (
      <Box
        sx={{
          width: ARTWORK_SIZE,
          height: ARTWORK_SIZE,
          marginTop: SPACING,
          paddingRight: SPACING,
        }}
      >
        {artworkFileURL ? (
          <img
            src={artworkFileURL}
            alt="artwork"
            width={ARTWORK_SIZE}
            height={ARTWORK_SIZE}
          />
        ) : (
          <DelayedElement>
            <div
              style={{
                width: ARTWORK_SIZE,
                height: ARTWORK_SIZE,
                display: "flex",
                alignItems: "center",
              }}
            >
              <CircularProgress size={SPINNER_SIZE} />
            </div>
          </DelayedElement>
        )}
      </Box>
    );
  } else {
    return null;
  }
}

export default Artwork;
