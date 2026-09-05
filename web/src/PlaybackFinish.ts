// the effective finish point of a track: its trim finish, or the full duration
// when the finish is unset (0) in the library data
export function trackFinish(track: {
  finish: number;
  duration: number;
}): number {
  return track.finish > 0 ? track.finish : track.duration;
}

// whether playback has reached the trim finish and should advance to the next
// track. it requires having played past the start so a transient timeupdate
// during a track switch or seek can't skip immediately. a manual seek at or
// past the finish sets playedPastFinish, letting the track play out to its real
// end rather than skipping here
export function shouldSkipAtFinish(
  currentTime: number,
  start: number,
  finish: number,
  playedPastFinish: boolean
): boolean {
  return !playedPastFinish && currentTime > start && currentTime >= finish;
}

export interface AudioFinishState {
  // the track the audio element's src was last set to
  srcTrackId: string | undefined;
  seeking: boolean;
  readyState: number;
  ended: boolean;
}

// true only once the audio element has settled on the given track's source.
// guards finish detection against stale readings while a new track is still
// loading/seeking
export function audioSettledOnTrack(
  audio: AudioFinishState,
  trackId: string
): boolean {
  return (
    audio.srcTrackId === trackId &&
    !audio.seeking &&
    audio.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA
  );
}

// whether an ended event should finish the track. the media pipeline queues
// ended from its own thread, so one fired at the real end of a track can land
// after the finish check has already advanced to the next track. by then the
// audio element is loading a new source and is no longer ended, and acting on
// it would skip that track and record it as a play
export function shouldFinishAtEnded(
  audio: AudioFinishState,
  trackId: string
): boolean {
  return audioSettledOnTrack(audio, trackId) && audio.ended;
}
