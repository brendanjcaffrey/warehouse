// notches only render within a second of this distance from the real ends
const NOTCH_EDGE_THRESHOLD = 1;

export interface TrackProgress {
  duration: number;
  // effective trim points, with finish falling back to duration when unset
  start: number;
  finish: number;
  // fractional positions (0..1) for the start/finish notches, null when the
  // notch sits within a second of the real start (0) or finish (duration)
  startNotch: number | null;
  finishNotch: number | null;
}

export function trackProgress(track?: {
  duration: number;
  start: number;
  finish: number;
}): TrackProgress {
  const duration = track?.duration ?? 0;
  const start = track?.start ?? 0;
  // finish can be 0/unset in the library data - fall back to the duration
  const finish = track && track.finish > 0 ? track.finish : duration;
  const startNotch =
    duration > 0 && start > NOTCH_EDGE_THRESHOLD ? start / duration : null;
  const finishNotch =
    duration > 0 && duration - finish > NOTCH_EDGE_THRESHOLD
      ? finish / duration
      : null;
  return { duration, start, finish, startNotch, finishNotch };
}
