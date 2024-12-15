import { useState } from "react";
import { styled } from "@mui/material";
import { Box, Typography, Slider } from "@mui/material";
import { KeyboardReturnRounded } from "@mui/icons-material";

const DurationText = styled(Typography)({
  color: "#888",
  fontSize: "12px",
  marginTop: "auto",
});

function TrackDisplay() {
  const duration = 200; // seconds
  const [position, setPosition] = useState(32);
  const [returnDown, setReturnDown] = useState(false);

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
    <>
      <Box
        sx={{
          display: "flex",
          justifyContent: "space-between",
          marginBottom: "-12px",
        }}
      >
        <DurationText>{formatDuration(position)}</DurationText>
        <Box sx={{ display: "flex", alignItems: "center" }}>
          <Box sx={{ textAlign: "center" }}>
            <Typography
              noWrap
              sx={{ color: "#444", fontSize: "14px", lineHeight: "20px" }}
            >
              Name
              <span onMouseDown={returnButtonDown} onMouseUp={returnButtonUp}>
                <KeyboardReturnRounded
                  sx={{
                    fontSize: "12px",
                    cursor: "pointer",
                    pl: "2px",
                    color: returnDown ? "#ccc" : "#444",
                  }}
                />
              </span>
            </Typography>
            <Typography
              sx={{ color: "#888", fontSize: "12px", lineHeight: "17.15px" }}
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
          color: "#888",
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
    </>
  );
}

export default TrackDisplay;
