import { useAtom } from "jotai";
import { Stack, Slider, IconButton } from "@mui/material";
import {
  FastForwardRounded,
  FastRewindRounded,
  PauseRounded,
  PlayArrowRounded,
  RepeatRounded,
  ShuffleRounded,
} from "@mui/icons-material";
import { shuffleAtom, repeatAtom, volumeAtom } from "./Settings";
import { playingAtom } from "./Player";

function Controls() {
  const [playing, setPlaying] = useAtom(playingAtom);
  const [shuffle, setShuffle] = useAtom(shuffleAtom);
  const [repeat, setRepeat] = useAtom(repeatAtom);
  const [volume, setVolume] = useAtom(volumeAtom);

  const togglePlaying = () => {
    setPlaying((prev) => !prev);
  };

  const toggleShuffle = () => {
    setShuffle((prev) => !prev);
  };

  const toggleRepeat = () => {
    setRepeat((prev) => !prev);
  };

  const volumeChange = (_: Event, newValue: number | number[]) => {
    setVolume(newValue as number);
  };

  return (
    <div>
      <Stack direction="row" sx={{ alignItems: "center" }}>
        <IconButton size="large" color="inherit">
          <FastRewindRounded fontSize="inherit" />
        </IconButton>
        <IconButton
          size="large"
          onClick={togglePlaying}
          edge="start"
          color="inherit"
        >
          {playing ? (
            <PauseRounded fontSize="inherit" />
          ) : (
            <PlayArrowRounded fontSize="inherit" />
          )}
        </IconButton>
        <IconButton size="large" edge="start" color="inherit">
          <FastForwardRounded fontSize="inherit" />
        </IconButton>
        <IconButton
          size="large"
          onClick={toggleShuffle}
          color={shuffle ? "inherit" : "default"}
        >
          <ShuffleRounded fontSize="inherit" />
        </IconButton>
        <IconButton
          size="large"
          onClick={toggleRepeat}
          edge="start"
          color={repeat ? "inherit" : "default"}
        >
          <RepeatRounded fontSize="inherit" />
        </IconButton>
        <Slider
          value={volume}
          onChange={volumeChange}
          sx={() => ({
            maxWidth: "125px",
            ml: "12px",
            color: "rgba(0,0,0,0.5)",
            "& .MuiSlider-track": {
              border: "none",
            },
            "& .MuiSlider-thumb": {
              backgroundColor: "#fff",
              "&::before": {
                boxShadow: "0 4px 8px rgba(0,0,0,0.4)",
              },
              "&:hover, &.Mui-focusVisible, &.Mui-active": {
                boxShadow: "none",
              },
            },
          })}
        />
      </Stack>
    </div>
  );
}

export default Controls;
