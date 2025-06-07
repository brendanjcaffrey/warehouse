import { useState, useEffect } from "react";
import { useAtomValue } from "jotai";
import { Box, CircularProgress, Modal } from "@mui/material";
import DelayedElement from "./DelayedElement";
import { showArtworkAtom } from "./Settings";
import { playingTrackAtom } from "./State";
import { files } from "./Files";
import { useArtworkFileURL } from "./useArtworkFileURL";

const ARTWORK_SIZE = "40px";
const SPINNER_SIZE = "20px";
const SPACING = "4px";

function Artwork() {
  const showArtwork = useAtomValue(showArtworkAtom);
  const playingTrack = useAtomValue(playingTrackAtom);
  const [showModal, setShowModal] = useState(false);
  const [modalWidth, setModalWidth] = useState(0);
  const [modalHeight, setModalHeight] = useState(0);
  const artworkFileURL = useArtworkFileURL(playingTrack?.track);

  useEffect(() => {
    files(); // initialize it
  }, []);

  if (showArtwork && playingTrack && playingTrack.track.artwork) {
    return (
      <Box
        sx={{
          width: ARTWORK_SIZE,
          height: ARTWORK_SIZE,
          marginTop: SPACING,
          paddingRight: SPACING,
          cursor: artworkFileURL ? "pointer" : "auto",
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
                  const scale = Math.min(
                    (window.innerWidth * 0.8) / i.width,
                    (window.innerHeight * 0.8) / i.height,
                    1
                  );

                  setModalWidth(i.width * scale);
                  setModalHeight(i.height * scale);
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
                <img
                  src={artworkFileURL}
                  alt="artwork"
                  style={{
                    width: `${modalWidth}px`,
                    height: `${modalHeight}px`,
                  }}
                />
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
