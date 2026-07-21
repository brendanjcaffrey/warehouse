import { useAtom, useAtomValue } from "jotai";
import { Form, OverlayTrigger, Popover, Stack, Tooltip } from "react-bootstrap";
import {
  SkipEndFill,
  SkipStartFill,
  PauseFill,
  PlayFill,
  Repeat,
  Repeat1,
  Shuffle,
  Sliders,
  VolumeDownFill,
  VolumeUpFill,
} from "react-bootstrap-icons";
import {
  shuffleAtom,
  repeatAtom,
  nextRepeatMode,
  volumeAtom,
} from "./Settings";
import useBreakpoint from "@restart/hooks/useBreakpoint";
import IconButton from "./IconButton";
import { player } from "./Player";
import { playingAtom } from "./State";

const ACTIVE_COLOR = "var(--bs-body-color)";
const DISABLED_COLOR = "var(--bs-secondary-color)";
const TOGGLE_ON_COLOR = "var(--bs-primary)";

function Controls() {
  const isSmallScreen = useBreakpoint("lg", "down");

  const [shuffle, setShuffle] = useAtom(shuffleAtom);
  const [repeat, setRepeat] = useAtom(repeatAtom);
  const volume = useAtomValue(volumeAtom);
  const playing = useAtomValue(playingAtom);

  const toggleShuffle = () => {
    const next = !shuffle;
    setShuffle(next);
    player().setShuffled(next);
  };

  const toggleRepeat = () => {
    setRepeat((prev) => nextRepeatMode(prev));
  };

  const repeatActive = repeat !== "off";
  const RepeatIcon = repeat === "one" ? Repeat1 : Repeat;
  const repeatTooltip =
    repeat === "off"
      ? "Repeat Off"
      : repeat === "all"
        ? "Repeat All"
        : "Repeat Track";

  const volumeChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    player().setVolume(Number(e.target.value));
  };

  const alwaysShownItems = (
    <>
      <IconButton onClick={() => player().prev()}>
        <SkipStartFill size={30} color={ACTIVE_COLOR} />
      </IconButton>
      <IconButton onClick={() => player().playPause()}>
        {playing ? (
          <PauseFill size={30} color={ACTIVE_COLOR} />
        ) : (
          <PlayFill size={30} color={ACTIVE_COLOR} />
        )}
      </IconButton>
      <IconButton onClick={() => player().next()}>
        <SkipEndFill size={30} color={ACTIVE_COLOR} />
      </IconButton>
    </>
  );

  const possiblyHiddenItems = (
    <>
      <OverlayTrigger
        placement="bottom"
        overlay={<Tooltip>{shuffle ? "Shuffle On" : "Shuffle Off"}</Tooltip>}
      >
        <IconButton onClick={toggleShuffle}>
          <Shuffle
            size={26}
            color={shuffle ? TOGGLE_ON_COLOR : DISABLED_COLOR}
          />
        </IconButton>
      </OverlayTrigger>
      <OverlayTrigger
        placement="bottom"
        overlay={<Tooltip>{repeatTooltip}</Tooltip>}
      >
        <IconButton onClick={toggleRepeat}>
          <RepeatIcon
            size={26}
            color={repeatActive ? TOGGLE_ON_COLOR : DISABLED_COLOR}
          />
        </IconButton>
      </OverlayTrigger>
      <VolumeDownFill
        size={16}
        color={DISABLED_COLOR}
        style={{ marginLeft: "24px", flexShrink: 0 }}
      />
      <Form.Range
        className="volume-range"
        value={volume}
        onChange={volumeChange}
        style={
          {
            maxWidth: "125px",
            marginLeft: "6px",
            marginRight: "6px",
            "--range-fill": `${volume}%`,
          } as React.CSSProperties
        }
      />
      <VolumeUpFill
        size={16}
        color={DISABLED_COLOR}
        style={{ flexShrink: 0 }}
      />
    </>
  );

  return (
    <Stack direction="horizontal">
      {alwaysShownItems}
      <div style={{ width: "16px", flexShrink: 0 }} />
      {isSmallScreen ? (
        <OverlayTrigger
          trigger="click"
          rootClose
          placement="bottom-start"
          overlay={
            <Popover>
              <Popover.Body style={{ minWidth: 240 }}>
                <Stack direction="horizontal">{possiblyHiddenItems}</Stack>
              </Popover.Body>
            </Popover>
          }
        >
          <IconButton>
            <Sliders size={26} color={ACTIVE_COLOR} />
          </IconButton>
        </OverlayTrigger>
      ) : (
        possiblyHiddenItems
      )}
    </Stack>
  );
}

export default Controls;
