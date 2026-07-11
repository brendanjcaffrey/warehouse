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
