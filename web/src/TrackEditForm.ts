import { Track } from "./Library";
import { TrackUpdate } from "./generated/messages";
import { FormatPlaybackPositionWithMillis } from "./PlaybackPositionFormatters";

// ratings are stored 0-100 but shown as five stars in half steps, like itunes
export const RATING_PER_STAR = 20;

// years are pushed back into itunes as an int32, so anything larger is rejected
const MAX_INT32 = 2147483647;

// m:ss.mmm parser mirroring the ios edit form: strict minutes:seconds with up
// to three optional millis digits, returning null when it doesn't match
export function parsePlaybackTime(value: string): number | null {
  const match = value.match(/^(\d+):([0-5]\d)(?:\.(\d{0,3}))?$/);
  if (!match) {
    return null;
  }
  const minutes = Number(match[1]);
  const seconds = Number(match[2]);
  const fraction = match[3] ? Number(`0.${match[3]}`) : 0;
  return minutes * 60 + seconds + fraction;
}

// the edit form's working copy of a track's editable fields, kept as the
// strings being typed; mirrors the ios edit form: only changed fields are
// submitted and sort names go stale until the next sync
export interface TrackEditForm {
  name: string;
  artist: string;
  album: string;
  albumArtist: string;
  genre: string;
  year: string;
  start: string;
  finish: string;
  // in stars, 0 to 5 in half steps
  rating: number;
}

export function formFromTrack(track: Track): TrackEditForm {
  return {
    name: track.name,
    artist: track.artistName,
    album: track.albumName,
    albumArtist: track.albumArtistName,
    genre: track.genre,
    year: String(track.year),
    start: FormatPlaybackPositionWithMillis(track.start),
    finish: FormatPlaybackPositionWithMillis(track.finish),
    rating: track.rating / RATING_PER_STAR,
  };
}

export const isNameValid = (form: TrackEditForm) => form.name !== "";
export const isArtistValid = (form: TrackEditForm) => form.artist !== "";
export const isGenreValid = (form: TrackEditForm) => form.genre !== "";
export const isYearValid = (form: TrackEditForm) =>
  /^\d+$/.test(form.year) && Number(form.year) <= MAX_INT32;

export const isStartValid = (form: TrackEditForm, duration: number) =>
  isPositionValid(form.start, duration);
export const isFinishValid = (form: TrackEditForm, duration: number) =>
  isPositionValid(form.finish, duration);

function isPositionValid(value: string, duration: number): boolean {
  const seconds = parsePlaybackTime(value);
  return seconds !== null && seconds < duration + 0.0005;
}

export function isFormValid(form: TrackEditForm, duration: number): boolean {
  return (
    isNameValid(form) &&
    isArtistValid(form) &&
    isGenreValid(form) &&
    isYearValid(form) &&
    isStartValid(form, duration) &&
    isFinishValid(form, duration)
  );
}

function ratingValue(form: TrackEditForm): number {
  return Math.round(form.rating * RATING_PER_STAR);
}

// a track update carrying only the fields that differ from the track, matching
// the ios edit form; start & finish are sent as seconds
export function changedFields(form: TrackEditForm, track: Track): TrackUpdate {
  const update = new TrackUpdate();
  if (form.name !== track.name) {
    update.name = form.name;
  }
  if (form.artist !== track.artistName) {
    update.artist = form.artist;
  }
  if (form.album !== track.albumName) {
    update.album = form.album;
  }
  if (form.albumArtist !== track.albumArtistName) {
    update.albumArtist = form.albumArtist;
  }
  if (form.genre !== track.genre) {
    update.genre = form.genre;
  }
  if (form.year !== String(track.year) && /^\d+$/.test(form.year)) {
    update.year = Number(form.year);
  }
  const start = parsePlaybackTime(form.start);
  if (
    form.start !== FormatPlaybackPositionWithMillis(track.start) &&
    start !== null
  ) {
    update.start = start;
  }
  const finish = parsePlaybackTime(form.finish);
  if (
    form.finish !== FormatPlaybackPositionWithMillis(track.finish) &&
    finish !== null
  ) {
    update.finish = finish;
  }
  if (ratingValue(form) !== track.rating) {
    update.rating = ratingValue(form);
  }
  return update;
}

// whether an update carries any field, so an unchanged save can skip the push
export function hasChanges(update: TrackUpdate): boolean {
  return (
    update.has_name ||
    update.has_artist ||
    update.has_album ||
    update.has_albumArtist ||
    update.has_genre ||
    update.has_year ||
    update.has_start ||
    update.has_finish ||
    update.has_rating
  );
}

// a copy of the track with the edits applied; sort names are left as they were
// until the next sync, matching the ios edit form
export function updatedTrack(form: TrackEditForm, track: Track): Track {
  return {
    ...track,
    name: form.name,
    artistName: form.artist,
    albumName: form.album,
    albumArtistName: form.albumArtist,
    genre: form.genre,
    year: /^\d+$/.test(form.year) ? Number(form.year) : track.year,
    start: parsePlaybackTime(form.start) ?? track.start,
    finish: parsePlaybackTime(form.finish) ?? track.finish,
    rating: ratingValue(form),
  };
}
