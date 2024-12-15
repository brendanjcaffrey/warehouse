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
import { playingAtom } from "./State";
import { defaultGrey, darkerGrey, titleGrey } from "./Colors";

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
        <IconButton size="large">
          <FastRewindRounded fontSize="inherit" sx={{ color: titleGrey }} />
        </IconButton>
        <IconButton size="large" onClick={togglePlaying} edge="start">
          {playing ? (
            <PauseRounded fontSize="inherit" sx={{ color: titleGrey }} />
          ) : (
            <PlayArrowRounded fontSize="inherit" sx={{ color: titleGrey }} />
          )}
        </IconButton>
        <IconButton size="large" edge="start">
          <FastForwardRounded fontSize="inherit" sx={{ color: titleGrey }} />
        </IconButton>
        <IconButton
          size="large"
          onClick={toggleShuffle}
          sx={{ color: shuffle ? titleGrey : defaultGrey }}
        >
          <ShuffleRounded fontSize="inherit" />
        </IconButton>
        <IconButton
          size="large"
          onClick={toggleRepeat}
          edge="start"
          sx={{ color: repeat ? titleGrey : defaultGrey }}
        >
          <RepeatRounded fontSize="inherit" />
        </IconButton>
        <Slider
          value={volume}
          onChange={volumeChange}
          sx={() => ({
            maxWidth: "125px",
            ml: "12px",
            color: defaultGrey,
            "& .MuiSlider-track": {
              border: "none",
            },
            "& .MuiSlider-thumb": {
              backgroundColor: "#fff",
              border: `1px solid ${darkerGrey}`,
              "&::before": {
                boxShadow: "none",
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
