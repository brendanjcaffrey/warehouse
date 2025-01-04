import { useState, useEffect, useCallback } from "react";
import { useAtomValue } from "jotai";
import { Box } from "@mui/material";
import { playingTrackAtom } from "./State";
import { DownloadWorker } from "./DownloadWorkerHandle";
import {
  isTypedMessage,
  isArtworkFetchedMessage,
  FETCH_ARTWORK_TYPE,
} from "./WorkerTypes";

const ARTWORK_SIZE = "40px";
const SPACING = "4px";

function Artwork() {
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
        setShownArtwork(artworkFilename);
        setArtworkFileURL(URL.createObjectURL(file));
      } catch (e) {
        console.error("unable to get fetched artwork", e);
      }
    },
    [artworkDirHandle, setShownArtwork, setArtworkFileURL]
  );

  useEffect(() => {
    getArtworkDirHandle();
  }, []);

  useEffect(() => {
    DownloadWorker.onmessage = (m: MessageEvent) => {
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
    };
    return () => {
      DownloadWorker.onmessage = null;
    };
  }, [playingTrack, showFetchedArtwork]);

  useEffect(() => {
    if (
      playingTrack &&
      artworkDirHandle &&
      playingTrack.artworks[0] !== shownArtwork
    ) {
      const artworkFilename = playingTrack.artworks[0];
      if (artworkFilename) {
        DownloadWorker.postMessage({
          type: FETCH_ARTWORK_TYPE,
          artworkFilename: artworkFilename,
        });
        setShownArtwork(null);
        if (artworkFileURL) {
          URL.revokeObjectURL(artworkFileURL);
          setArtworkFileURL(null);
        }
      } else {
        setArtworkFileURL(null);
      }
    }
  }, [playingTrack, artworkFileURL, shownArtwork, artworkDirHandle]);

  if (artworkFileURL) {
    return (
      <Box
        sx={{
          width: ARTWORK_SIZE,
          height: ARTWORK_SIZE,
          marginTop: SPACING,
          paddingRight: SPACING,
        }}
      >
        <img
          src={artworkFileURL}
          alt="artwork"
          width={ARTWORK_SIZE}
          height={ARTWORK_SIZE}
        />
      </Box>
    );
  } else {
    return null;
  }
}

export default Artwork;
