import { useState, useEffect, useCallback } from "react";
import { useAtomValue } from "jotai";
import { Box, CircularProgress } from "@mui/material";
import DelayedElement from "./DelayedElement";
import { showArtworkAtom } from "./Settings";
import { playingTrackAtom } from "./State";
import { DownloadWorker } from "./DownloadWorkerHandle";
import { files } from "./Files";
import { isTypedMessage, isArtworkFetchedMessage } from "./WorkerTypes";

const ARTWORK_SIZE = "40px";
const SPINNER_SIZE = "20px";
const SPACING = "4px";

function Artwork() {
  const showArtwork = useAtomValue(showArtworkAtom);
  const playingTrack = useAtomValue(playingTrackAtom);
  const [shownArtwork, setShownArtwork] = useState<string | null>(null);
  const [artworkFileURL, setArtworkFileURL] = useState<string | null>(null);

  useEffect(() => {
    files(); // initialize it
  }, []);

  const showFetchedArtwork = useCallback(
    async (artworkId: string) => {
      const url = await files().tryGetArtworkURL(artworkId);
      if (url) {
        setArtworkFileURL(url);
      } else {
        // nop, Player handles downloading artwork, so wait for a message to come in from the worker
      }
    },
    [setArtworkFileURL]
  );

  const handleDownloadWorkerMessage = useCallback(
    (m: MessageEvent) => {
      const { data } = m;
      if (!isTypedMessage(data)) {
        return;
      }
      if (
        isArtworkFetchedMessage(data) &&
        data.artworkId === playingTrack?.artworks[0]
      ) {
        showFetchedArtwork(data.artworkId);
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
    if (playingTrack && playingTrack.artworks[0] !== shownArtwork) {
      if (artworkFileURL) {
        URL.revokeObjectURL(artworkFileURL);
        setArtworkFileURL(null);
      }

      const artworkId = playingTrack.artworks[0];
      if (artworkId) {
        setShownArtwork(artworkId);
        showFetchedArtwork(artworkId);
      } else {
        setShownArtwork(null);
      }
    }
  }, [playingTrack, artworkFileURL, shownArtwork, showFetchedArtwork]);

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
