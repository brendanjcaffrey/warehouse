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

function NowPlaying() {
  const isSmallScreen = useBreakpoint("md", "down");

  const [returnDown, setReturnDown] = useState(false);
  const showTrackFn = useAtomValue(showTrackFnAtom);
  const playingTrack = useAtomValue(playingTrackAtom);
  const currentTime = useAtomValue(currentTimeAtom);
  const waitingForMusicDownload = useAtomValue(waitingForMusicDownloadAtom);
  const remaining = playingTrack ? playingTrack.track.finish - currentTime : 0;

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
                  ...NO_WRAP,
                }}
              >
                {waitingForMusicDownload && (
                  <DelayedElement>
                    <span style={{ paddingRight: "4px" }}>
                      <Spinner
                        animation="border"
                        style={{ width: 10, height: 10, borderWidth: 1.5 }}
                      />
                    </span>
                  </DelayedElement>
                )}
                {playingTrack?.track.name || <span>&nbsp;</span>}
                {playingTrack && (
                  <span
                    onMouseDown={returnButtonDown}
                    onMouseUp={returnButtonUp}
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
        <Form.Range
          className="track-progress"
          value={currentTime}
          min={playingTrack?.track.start ?? 0}
          max={playingTrack?.track.finish ?? 0}
          onChange={(e) => player().setCurrentTime(Number(e.target.value))}
          style={{ marginTop: "0px" }}
        />
      </div>
    </Stack>
  );
}

export default NowPlaying;
