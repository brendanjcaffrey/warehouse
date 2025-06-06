import { useState } from "react";
import { useAtom, useAtomValue } from "jotai";
import {
  useTheme,
  useMediaQuery,
  Box,
  Stack,
  Slider,
  IconButton,
  Tooltip,
  Popover,
} from "@mui/material";
import {
  SkipNextRounded,
  SkipPreviousRounded,
  PauseRounded,
  PlayArrowRounded,
  RepeatRounded,
  ShuffleRounded,
  TuneRounded,
} from "@mui/icons-material";
import { shuffleAtom, repeatAtom, volumeAtom } from "./Settings";
import { player } from "./Player";
import { playingAtom } from "./State";

function Controls() {
  const theme = useTheme();
  const isSmallScreen = useMediaQuery(theme.breakpoints.down("lg"));

  const [popoverAnchorEl, setPopoverAnchorEl] = useState<null | HTMLElement>(
    null
  );
  const popoverOpen = Boolean(popoverAnchorEl);
  const handleOpenPopover = (event: React.MouseEvent<HTMLButtonElement>) => {
    setPopoverAnchorEl(event.currentTarget);
  };
  const handleClosePopover = () => {
    setPopoverAnchorEl(null);
  };

  const [shuffle, setShuffle] = useAtom(shuffleAtom);
  const [repeat, setRepeat] = useAtom(repeatAtom);
  const volume = useAtomValue(volumeAtom);
  const playing = useAtomValue(playingAtom);

  const toggleShuffle = () => {
    setShuffle((prev) => !prev);
    player().shuffleChanged();
  };

  const toggleRepeat = () => {
    setRepeat((prev) => !prev);
  };

  const volumeChange = (_: Event, newValue: number | number[]) => {
    player().setVolume(newValue as number);
  };

  const alwaysShownItems = (
    <>
      <IconButton size="large" onClick={() => player().prev()}>
        <SkipPreviousRounded fontSize="inherit" color="action" />
      </IconButton>
      <IconButton
        size="large"
        onClick={() => player().playPause()}
        edge="start"
      >
        {playing ? (
          <PauseRounded fontSize="inherit" color="action" />
        ) : (
          <PlayArrowRounded fontSize="inherit" color="action" />
        )}
      </IconButton>
      <IconButton size="large" edge="start" onClick={() => player().next()}>
        <SkipNextRounded fontSize="inherit" color="action" />
      </IconButton>
    </>
  );

  const possiblyHiddenItems = (
    <>
      <Tooltip title="Shuffle Playlist">
        <IconButton size="large" onClick={toggleShuffle}>
          <ShuffleRounded
            color={shuffle ? "action" : "disabled"}
            fontSize="inherit"
          />
        </IconButton>
      </Tooltip>
      <Tooltip title="Repeat Track">
        <IconButton size="large" onClick={toggleRepeat} edge="start">
          <RepeatRounded
            color={repeat ? "action" : "disabled"}
            fontSize="inherit"
          />
        </IconButton>
      </Tooltip>
      <Slider
        value={volume}
        onChange={volumeChange}
        sx={() => ({
          maxWidth: "125px",
          ml: "12px",
          color: theme.palette.action.disabled,
          "& .MuiSlider-track": {
            border: "none",
          },
          "& .MuiSlider-thumb": {
            width: "16px",
            height: "16px",
            backgroundColor: theme.palette.grey[500],
            "&::before": {
              boxShadow: "none",
            },
            "&:hover, &.Mui-focusVisible, &.Mui-active": {
              boxShadow: "none",
            },
          },
        })}
      />
    </>
  );

  if (isSmallScreen) {
    return (
      <div>
        <Stack direction="row" sx={{ alignItems: "center" }}>
          {alwaysShownItems}
          <IconButton onClick={handleOpenPopover}>
            <TuneRounded />
          </IconButton>
          <Popover
            open={popoverOpen}
            anchorEl={popoverAnchorEl}
            onClose={handleClosePopover}
            anchorOrigin={{
              vertical: "bottom",
              horizontal: "left",
            }}
          >
            <Box sx={{ minWidth: 240 }}>
              <Stack direction="row" sx={{ alignItems: "center" }}>
                {possiblyHiddenItems}
              </Stack>
            </Box>
          </Popover>
        </Stack>
      </div>
    );
  } else {
    return (
      <div>
        <Stack direction="row" sx={{ alignItems: "center" }}>
          {alwaysShownItems}
          {possiblyHiddenItems}
        </Stack>
      </div>
    );
  }
}

export default Controls;
