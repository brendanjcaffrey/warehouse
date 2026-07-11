import { ReactNode, useState } from "react";
import { useAtomValue } from "jotai";
import { Form, Spinner, Stack } from "react-bootstrap";
import { ArrowReturnLeft } from "react-bootstrap-icons";
import Artwork from "./Artwork";
import DelayedElement from "./DelayedElement";
import useBreakpoint from "@restart/hooks/useBreakpoint";
import { player } from "./Player";
import {
  showTrackFnAtom,
  playingTrackAtom,
  currentTimeAtom,
  waitingForMusicDownloadAtom,
} from "./State";
import { FormatPlaybackPosition } from "./PlaybackPositionFormatters";
import { trackProgress } from "./TrackProgress";

const NO_WRAP: React.CSSProperties = {
  whiteSpace: "nowrap",
  overflow: "hidden",
  textOverflow: "ellipsis",
};

function DurationText({
  children,
  style,
}: {
  children: ReactNode;
  style?: React.CSSProperties;
}) {
  return (
    <span
      style={{
        fontSize: "12px",
        marginTop: "auto",
        color: "var(--bs-secondary-color)",
        ...style,
      }}
    >
      {children}
    </span>
  );
}

// vertical tick marking the trim start/finish over the progress bar, hidden
// by the caller when it sits within a second of the real track ends
function TrimNotch({ position }: { position: number }) {
  return (
    <div
      style={{
        position: "absolute",
        left: `${position * 100}%`,
        top: "50%",
        transform: "translate(-50%, -50%)",
        width: "2px",
        height: "0.6rem",
        backgroundColor: "var(--bs-secondary-color)",
        pointerEvents: "none",
      }}
    />
  );
}

function NowPlaying() {
  const isSmallScreen = useBreakpoint("md", "down");

  const [returnDown, setReturnDown] = useState(false);
  const showTrackFn = useAtomValue(showTrackFnAtom);
  const playingTrack = useAtomValue(playingTrackAtom);
  const currentTime = useAtomValue(currentTimeAtom);
  const waitingForMusicDownload = useAtomValue(waitingForMusicDownloadAtom);
  const { duration, startNotch, finishNotch } = trackProgress(
    playingTrack?.track
  );
  const remaining = playingTrack ? Math.max(0, duration - currentTime) : 0;
  const progressPercent =
    duration > 0
      ? Math.min(100, Math.max(0, (currentTime / duration) * 100))
      : 0;

  function returnButtonDown() {
    setReturnDown(true);
  }
  function returnButtonUp() {
    setReturnDown(false);
    if (playingTrack) {
      showTrackFn.fn({
        playlistId: playingTrack.playlistId,
        playlistOffset: playingTrack.playlistOffset,
      });
    }
  }

  return (
    <Stack direction="horizontal" className="w-100">
      <div>
        <Artwork />
      </div>
      <div style={{ width: "100%", color: "var(--bs-body-color)" }}>
        <div
          style={{
            display: "flex",
            justifyContent: "space-between",
            marginBottom: "-12px",
            marginTop: "4px",
          }}
        >
          <DurationText style={{ paddingRight: "4px" }}>
            {FormatPlaybackPosition(currentTime)}
          </DurationText>
          <div
            style={{
              display: "flex",
              alignItems: "center",
              maxWidth: isSmallScreen ? "70%" : "85%",
            }}
          >
            <div style={{ textAlign: "center", maxWidth: "100%" }}>
              <div
                style={{
                  fontSize: "14px",
                  lineHeight: "20px",
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                  minWidth: 0,
                }}
              >
                {waitingForMusicDownload && (
                  <DelayedElement>
                    <span style={{ paddingRight: "4px", flexShrink: 0 }}>
                      <Spinner
                        animation="border"
                        style={{ width: 10, height: 10, borderWidth: 1.5 }}
                      />
                    </span>
                  </DelayedElement>
                )}
                {/* only the title truncates, so the return button stays visible */}
                <span style={NO_WRAP}>
                  {playingTrack?.track.name || <span>&nbsp;</span>}
                </span>
                {playingTrack && (
                  <span
                    onMouseDown={returnButtonDown}
                    onMouseUp={returnButtonUp}
                    style={{ flexShrink: 0 }}
                  >
                    <ArrowReturnLeft
                      size={12}
                      color={
                        returnDown
                          ? "var(--bs-secondary-color)"
                          : "var(--bs-body-color)"
                      }
                      style={{ cursor: "pointer", marginLeft: "2px" }}
                    />
                  </span>
                )}
              </div>
              <div
                style={{
                  fontSize: "12px",
                  lineHeight: "17.15px",
                  color: "var(--bs-secondary-color)",
                  ...NO_WRAP,
                }}
              >
                {playingTrack?.track.artistName || ""}
                {playingTrack?.track.albumName && " - "}
                {playingTrack?.track.albumName || ""}
                {!playingTrack && <span>&nbsp;</span>}
              </div>
            </div>
          </div>
          <DurationText style={{ paddingLeft: "4px" }}>
            -{FormatPlaybackPosition(remaining)}
          </DurationText>
        </div>
        <div style={{ position: "relative" }}>
          <Form.Range
            className="track-progress"
            value={currentTime}
            min={0}
            max={duration}
            onChange={(e) => player().setCurrentTime(Number(e.target.value))}
            style={
              {
                marginTop: "0px",
                "--range-fill": `${progressPercent}%`,
              } as React.CSSProperties
            }
          />
          {startNotch !== null && <TrimNotch position={startNotch} />}
          {finishNotch !== null && <TrimNotch position={finishNotch} />}
        </div>
      </div>
    </Stack>
  );
}

export default NowPlaying;
