import { useAtomValue } from "jotai";
import { VolumeUpFill } from "react-bootstrap-icons";
import { playingAtom, playingTrackAtom } from "./State";

// the marker itunes puts beside the track that's playing, shown in every list
// the track appears in. it becomes a pause glyph while playback is paused so a
// paused list doesn't read as still playing. renders nothing for other tracks
function PlayingIndicator({ trackId }: { trackId: string }) {
  const playingTrack = useAtomValue(playingTrackAtom);
  const playing = useAtomValue(playingAtom);

  if (playingTrack?.track.id !== trackId) {
    return null;
  }

  return (
    <span
      data-testid="playing-indicator"
      aria-label={playing ? "playing" : "paused"}
      className="text-primary d-inline-flex flex-shrink-0 align-middle ms-1"
    >
      <VolumeUpFill size={16} color={"var(--bs-secondary-color)"} />
    </span>
  );
}

export default PlayingIndicator;
