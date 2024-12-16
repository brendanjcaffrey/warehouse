import { useState } from "react";
import { useAtomValue } from "jotai";
import { styled } from "@mui/material";
import { Box, Stack, Typography, Slider } from "@mui/material";
import { KeyboardReturnRounded } from "@mui/icons-material";
import Artwork from "./Artwork";
import { lighterGrey, titleGrey, defaultGrey } from "./Colors";
import { showArtworkAtom } from "./Settings";

const DurationText = styled(Typography)({
  color: defaultGrey,
  fontSize: "12px",
  marginTop: "auto",
});

function TrackDisplay() {
  const duration = 200; // seconds
  const [position, setPosition] = useState(32);
  const [returnDown, setReturnDown] = useState(false);
  const showArtwork = useAtomValue(showArtworkAtom);

  function formatDuration(value: number) {
    const minute = Math.floor(value / 60);
    const secondLeft = value - minute * 60;
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
      <Box>{showArtwork && <Artwork />}</Box>
      <Box sx={{ width: "100%" }}>
        <Box
          sx={{
            display: "flex",
            justifyContent: "space-between",
            marginBottom: "-12px",
            marginTop: "4px",
          }}
        >
          <DurationText>{formatDuration(position)}</DurationText>
          <Box sx={{ display: "flex", alignItems: "center" }}>
            <Box sx={{ textAlign: "center" }}>
              <Typography
                noWrap
                sx={{ color: titleGrey, fontSize: "14px", lineHeight: "20px" }}
              >
                Name
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
                Artist – Album
              </Typography>
            </Box>
          </Box>
          <DurationText>-{formatDuration(duration - position)}</DurationText>
        </Box>
        <Slider
          size="small"
          value={position}
          min={0}
          max={duration}
          onChange={(_, value) => setPosition(value as number)}
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

export default TrackDisplay;
