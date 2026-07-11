import { ReactNode } from "react";
import { useAtomValue } from "jotai";
import { Form, Spinner, Stack } from "react-bootstrap";
import { ThreeDots } from "react-bootstrap-icons";
import Artwork from "./Artwork";
import DelayedElement from "./DelayedElement";
import useBreakpoint from "@restart/hooks/useBreakpoint";
import { player } from "./Player";
import {
  playingTrackAtom,
  currentTimeAtom,
  waitingForMusicDownloadAtom,
} from "./State";
import { FormatPlaybackPosition } from "./PlaybackPositionFormatters";
import { trackProgress } from "./TrackProgress";
import { usePlaylists } from "./usePlaylists";
import { useReveal } from "./useReveal";
import { useTrackContextMenu } from "./TrackContextMenu";
import { resolvePlayingSource } from "./PlayingSource";

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

  const playingTrack = useAtomValue(playingTrackAtom);
  const currentTime = useAtomValue(currentTimeAtom);
  const waitingForMusicDownload = useAtomValue(waitingForMusicDownloadAtom);
  const playlists = usePlaylists();
  const revealTo = useReveal();
  // where the playing track is playing from, driving the return-to-source link
  // and the subtitle. null when it's an unknown playlist
  const source = playingTrack
    ? resolvePlayingSource(
        playingTrack.playlistId,
        playingTrack.track,
        playlists
      )
    : null;
  // exclude the playing playlist from the menu's "show in playlist" submenu
  const currentPlaylistId =
    source && source.reveal.view === "playlist"
      ? source.reveal.selectionId
      : undefined;
  const trackMenu = useTrackContextMenu(currentPlaylistId);
  const { duration, startNotch, finishNotch } = trackProgress(
    playingTrack?.track
  );
  const remaining = playingTrack ? Math.max(0, duration - currentTime) : 0;
  const progressPercent =
    duration > 0
      ? Math.min(100, Math.max(0, (currentTime / duration) * 100))
      : 0;

  return (
    <Stack direction="horizontal" className="w-100">
      <div style={{ alignSelf: "flex-start" }}>
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
                {/* only the title truncates, so the menu button stays visible */}
                <span style={NO_WRAP}>
                  {playingTrack?.track.name || <span>&nbsp;</span>}
                </span>
                {playingTrack && (
                  <span
                    role="button"
                    aria-label="track menu"
                    onClick={(event) =>
                      trackMenu.openMenu(
                        event,
                        playingTrack.track,
                        undefined,
                        source
                          ? {
                              label: source.label,
                              onClick: () =>
                                revealTo(source.reveal, source.path),
                            }
                          : undefined
                      )
                    }
                    style={{ flexShrink: 0, cursor: "pointer" }}
                  >
                    <ThreeDots size={14} style={{ marginLeft: "2px" }} />
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
      {trackMenu.element}
    </Stack>
  );
}

export default NowPlaying;
