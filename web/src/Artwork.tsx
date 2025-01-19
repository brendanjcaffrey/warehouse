import { useState, useEffect, useCallback } from "react";
import { useAtomValue } from "jotai";
import { Box, CircularProgress, Modal } from "@mui/material";
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
  const [showModal, setShowModal] = useState(false);
  const [shownArtwork, setShownArtwork] = useState<string | null>(null);
  const [artworkFileURL, setArtworkFileURL] = useState<string | null>(null);
  const [modalWidth, setModalWidth] = useState(0);
  const [modalHeight, setModalHeight] = useState(0);

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
      setShowModal(false);
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
          <>
            <img
              src={artworkFileURL}
              alt="artwork"
              width={ARTWORK_SIZE}
              height={ARTWORK_SIZE}
              onClick={() => {
                const i = new Image();
                i.onload = () => {
                  setModalWidth(i.width);
                  setModalHeight(i.height);
                  setShowModal(true);
                };
                i.src = artworkFileURL;
              }}
            />
            <Modal open={showModal} onClose={() => setShowModal(false)}>
              <Box
                sx={{
                  outline: 0,
                  position: "absolute",
                  top: "50%",
                  left: "50%",
                  transform: "translate(-50%, -50%)",
                  width: `${modalWidth}px`,
                  height: `${modalHeight}px`,
                }}
              >
                <img src={artworkFileURL} alt="artwork" />
              </Box>
            </Modal>
          </>
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
