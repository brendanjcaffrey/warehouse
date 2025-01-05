import { useState } from "react";
import { useAtomValue } from "jotai";
import { styled } from "@mui/material";
import { Box, Stack, Typography, Slider } from "@mui/material";
import { KeyboardReturnRounded } from "@mui/icons-material";
import Artwork from "./Artwork";
import { lighterGrey, titleGrey, defaultGrey } from "./Colors";
import { player } from "./Player";
import { playingTrackAtom, currentTimeAtom } from "./State";

const DurationText = styled(Typography)({
  color: defaultGrey,
  fontSize: "12px",
  marginTop: "auto",
});

function NowPlaying() {
  const [returnDown, setReturnDown] = useState(false);
  const playingTrack = useAtomValue(playingTrackAtom);
  const currentTime = useAtomValue(currentTimeAtom);
  const duration = playingTrack?.duration || 0;

  function formatSeconds(value: number) {
    const minute = Math.floor(value / 60);
    const secondLeft = Math.floor(value - minute * 60);
    return `${minute}:${secondLeft < 10 ? `0${secondLeft}` : secondLeft}`;
  }

  function returnButtonDown() {
    setReturnDown(true);
  }
  function returnButtonUp() {
    setReturnDown(false);
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
          <DurationText>{formatSeconds(currentTime)}</DurationText>
          <Box sx={{ display: "flex", alignItems: "center" }}>
            <Box sx={{ textAlign: "center" }}>
              <Typography
                noWrap
                sx={{ color: titleGrey, fontSize: "14px", lineHeight: "20px" }}
              >
                {playingTrack?.name || ""}
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
                sx={{
                  color: defaultGrey,
                  fontSize: "12px",
                  lineHeight: "17.15px",
                }}
              >
                {playingTrack?.artistName || ""}
                {playingTrack?.albumName && " - "}
                {playingTrack?.albumName || ""}
              </Typography>
            </Box>
          </Box>
          <DurationText>-{formatSeconds(duration - currentTime)}</DurationText>
        </Box>
        <Slider
          size="small"
          value={currentTime}
          min={0}
          max={playingTrack?.duration}
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
