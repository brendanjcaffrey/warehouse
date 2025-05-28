import { Track } from "./Library";
import { UnformatPlaybackPositionWithMillis } from "./PlaybackPositionFormatters";

export function ValidOptionalField(_: string, __: Track) {
  return true;
}

export function ValidRequiredField(v: string, _: Track) {
  return v.length > 0;
}

export function ValidYear(v: string, _: Track) {
  return /^[0-9]+$/.test(v);
}

export function ValidPlaybackPosition(v: string, t: Track) {
  return (
    /^[0-9]+:[0-5][0-9](\.[0-9]{0,3})?$/.test(v) &&
    UnformatPlaybackPositionWithMillis(v) < t.duration + 0.0005
  );
}
