import { useState, useEffect } from "react";
import { useAtomValue } from "jotai";
import { Spinner } from "react-bootstrap";
import DelayedElement from "./DelayedElement";
import { showArtworkAtom } from "./Settings";
import { playingTrackAtom } from "./State";
import { files } from "./Files";
import { useArtworkFileURL } from "./useArtworkFileURL";

const ARTWORK_SIZE = "40px";
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

  if (showArtwork && playingTrack && playingTrack.track.artworkFilename) {
    return (
      <div
        style={{
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
            {showModal && (
              <div
                onClick={() => setShowModal(false)}
                style={{
                  position: "fixed",
                  inset: 0,
                  zIndex: 1050,
                  backgroundColor: "rgba(0, 0, 0, 0.5)",
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
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
              </div>
            )}
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
              <Spinner animation="border" size="sm" />
            </div>
          </DelayedElement>
        )}
      </div>
    );
  } else {
    return null;
  }
}

export default Artwork;
