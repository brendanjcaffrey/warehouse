import { useAtom, useAtomValue } from "jotai";
import { Stack, Slider, IconButton, Tooltip } from "@mui/material";
import {
  SkipNextRounded,
  SkipPreviousRounded,
  PauseRounded,
  PlayArrowRounded,
  RepeatRounded,
  ShuffleRounded,
  ImageRounded,
} from "@mui/icons-material";
import {
  shuffleAtom,
  repeatAtom,
  showArtworkAtom,
  volumeAtom,
} from "./Settings";
import { player } from "./Player";
import { playingAtom } from "./State";
import { defaultGrey, darkerGrey, titleGrey } from "./Colors";

function Controls() {
  const [shuffle, setShuffle] = useAtom(shuffleAtom);
  const [repeat, setRepeat] = useAtom(repeatAtom);
  const [showArtwork, setShowArtwork] = useAtom(showArtworkAtom);
  const volume = useAtomValue(volumeAtom);
  const playing = useAtomValue(playingAtom);

  const toggleShuffle = () => {
    setShuffle((prev) => !prev);
    player().shuffleChanged();
  };

  const toggleRepeat = () => {
    setRepeat((prev) => !prev);
  };

  const toggleShowArtwork = () => {
    setShowArtwork((prev) => !prev);
  };

  const volumeChange = (_: Event, newValue: number | number[]) => {
    player().setVolume(newValue as number);
  };

  return (
    <div>
      <Stack direction="row" sx={{ alignItems: "center" }}>
        <IconButton size="large" onClick={() => player().prev()}>
          <SkipPreviousRounded fontSize="inherit" sx={{ color: titleGrey }} />
        </IconButton>
        <IconButton
          size="large"
          onClick={() => player().playPause()}
          edge="start"
        >
          {playing ? (
            <PauseRounded fontSize="inherit" sx={{ color: titleGrey }} />
          ) : (
            <PlayArrowRounded fontSize="inherit" sx={{ color: titleGrey }} />
          )}
        </IconButton>
        <IconButton size="large" edge="start" onClick={() => player().next()}>
          <SkipNextRounded fontSize="inherit" sx={{ color: titleGrey }} />
        </IconButton>
        <Tooltip title="Shuffle Playlist">
          <IconButton
            size="large"
            onClick={toggleShuffle}
            sx={{ color: shuffle ? titleGrey : defaultGrey }}
          >
            <ShuffleRounded fontSize="inherit" />
          </IconButton>
        </Tooltip>
        <Tooltip title="Repeat Track">
          <IconButton
            size="large"
            onClick={toggleRepeat}
            edge="start"
            sx={{ color: repeat ? titleGrey : defaultGrey }}
          >
            <RepeatRounded fontSize="inherit" />
          </IconButton>
        </Tooltip>
        <Tooltip title="Show Artwork">
          <IconButton
            size="large"
            onClick={toggleShowArtwork}
            edge="start"
            sx={{ color: showArtwork ? titleGrey : defaultGrey }}
          >
            <ImageRounded fontSize="inherit" />
          </IconButton>
        </Tooltip>
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
