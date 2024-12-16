import { useState, useEffect, useCallback } from "react";
import { atom, useAtomValue, useSetAtom } from "jotai";
import { Box } from "@mui/material";
import { ArtworkWorker } from "./ArtworkWorkerHandle";
import {
  isTypedMessage,
  isArtworkFetchedMessage,
  SET_AUTH_TOKEN_TYPE,
  FETCH_ARTWORK_TYPE,
} from "./WorkerTypes";

const ARTWORK_SIZE = "40px";
const SPACING = "4px";

const playingTrackArtworkAtom = atom<string | null>(null);

function Artwork() {
  const playingTrackArtwork = useAtomValue(playingTrackArtworkAtom);
  const setPlayingTrackArtwork = useSetAtom(playingTrackArtworkAtom);
  const [shownArtwork, setShownArtwork] = useState<string | null>(null);
  const [artworkFileURL, setArtworkFileURL] = useState<string | null>(null);
  const [artworkDirHandle, setArtworkDirHandle] =
    useState<FileSystemDirectoryHandle | null>(null);

  async function getArtworkDirHandle() {
    try {
      const mainDir = await navigator.storage.getDirectory();
      const artworkDirHanle = await mainDir.getDirectoryHandle("artwork", {
        create: true,
      });
      setArtworkDirHandle(artworkDirHanle);
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

    ArtworkWorker.postMessage({
      type: SET_AUTH_TOKEN_TYPE,
      authToken: localStorage.getItem("authToken"),
    });

    setPlayingTrackArtwork("57dca2fb504c3bb69387a3119eab94e5.jpg");
  }, [setPlayingTrackArtwork]);

  useEffect(() => {
    ArtworkWorker.onmessage = (m: MessageEvent) => {
      const { data } = m;
      if (!isTypedMessage(data)) {
        return;
      }
      if (
        isArtworkFetchedMessage(data) &&
        data.artworkFilename === playingTrackArtwork
      ) {
        showFetchedArtwork(data.artworkFilename);
      }
    };
    return () => {
      ArtworkWorker.onmessage = null;
    };
  }, [showFetchedArtwork, playingTrackArtwork]);

  useEffect(() => {
    if (
      playingTrackArtwork &&
      artworkDirHandle &&
      playingTrackArtwork !== shownArtwork
    ) {
      ArtworkWorker.postMessage({
        type: FETCH_ARTWORK_TYPE,
        artworkFilename: playingTrackArtwork,
      });
      setShownArtwork(null);
      if (artworkFileURL) {
        URL.revokeObjectURL(artworkFileURL);
        setArtworkFileURL(null);
      }
    }
  }, [playingTrackArtwork, artworkFileURL, shownArtwork, artworkDirHandle]);

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
