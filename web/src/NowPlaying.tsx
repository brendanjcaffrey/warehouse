import { useState } from "react";
import { useAtomValue } from "jotai";
import {
  useTheme,
  useMediaQuery,
  styled,
  CircularProgress,
} from "@mui/material";
import { Box, Stack, Typography, Slider } from "@mui/material";
import { KeyboardReturnRounded } from "@mui/icons-material";
import Artwork from "./Artwork";
import DelayedElement from "./DelayedElement";
import { lighterGrey, titleGrey, defaultGrey } from "./Colors";
import { player } from "./Player";
import {
  showTrackFnAtom,
  playingTrackAtom,
  currentTimeAtom,
  waitingForMusicDownloadAtom,
} from "./State";
import { FormatPlaybackPosition } from "./PlaybackPositionFormatters";

const DurationText = styled(Typography)({
  color: defaultGrey,
  fontSize: "12px",
  marginTop: "auto",
});

function NowPlaying() {
  const theme = useTheme();
  const isSmallScreen = useMediaQuery(theme.breakpoints.down("md"));

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
    <Stack direction="row">
      <Box>
        <Artwork />
      </Box>
      <Box sx={{ width: "100%" }}>
        <Box
          sx={{
            display: "flex",
            justifyContent: "space-between",
            marginBottom: "-12px",
            marginTop: "4px",
          }}
        >
          <DurationText sx={{ paddingRight: "4px" }}>
            {FormatPlaybackPosition(currentTime)}
          </DurationText>
          <Box
            sx={{
              display: "flex",
              alignItems: "center",
              maxWidth: isSmallScreen ? "70%" : "85%",
            }}
          >
            <Box sx={{ textAlign: "center", maxWidth: "100%" }}>
              <Typography
                noWrap
                sx={{
                  color: titleGrey,
                  fontSize: "14px",
                  lineHeight: "20px",
                }}
              >
                {waitingForMusicDownload && (
                  <DelayedElement>
                    <span style={{ paddingRight: "4px" }}>
                      <CircularProgress size={10} />
                    </span>
                  </DelayedElement>
                )}
                {playingTrack?.track.name || ""}
                <span onMouseDown={returnButtonDown} onMouseUp={returnButtonUp}>
                  <KeyboardReturnRounded
                    sx={{
                      fontSize: "12px",
                      cursor: "pointer",
                      pl: "2px",
                      color: returnDown ? lighterGrey : titleGrey,
                    }}
                  />
                </span>
              </Typography>
              <Typography
                noWrap
                sx={{
                  color: defaultGrey,
                  fontSize: "12px",
                  lineHeight: "17.15px",
                }}
              >
                {playingTrack?.track.artistName || ""}
                {playingTrack?.track.albumName && " - "}
                {playingTrack?.track.albumName || ""}
              </Typography>
            </Box>
          </Box>
          <DurationText sx={{ paddingLeft: "4px" }}>
            -{FormatPlaybackPosition(remaining)}
          </DurationText>
        </Box>
        <Slider
          size="small"
          value={currentTime}
          min={playingTrack?.track.start}
          max={playingTrack?.track.finish}
          onChange={(_, value) => player().setCurrentTime(value as number)}
          sx={() => ({
            color: defaultGrey,
            height: 4,
            mt: "0px",
            padding: "0",
            "& .MuiSlider-track": {
              border: "none",
            },
            "& .MuiSlider-thumb": {
              display: "none",
            },
            "& .MuiSlider-rail": {
              opacity: 0.28,
            },
          })}
        />
      </Box>
    </Stack>
  );
}

export default NowPlaying;
