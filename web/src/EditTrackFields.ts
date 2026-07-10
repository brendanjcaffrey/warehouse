import { Track } from "./Library";
import { TrackUpdate } from "./generated/messages";
import {
  FormatPlaybackPositionWithMillis,
  UnformatPlaybackPositionWithMillis,
} from "./PlaybackPositionFormatters";
import {
  ValidOptionalField,
  ValidRequiredField,
  ValidYear,
  ValidPlaybackPosition,
} from "./EditTrackFieldValidators";
import { parseInt } from "lodash";

export interface FieldDefinition {
  name: string;
  label: string;
  getDisplayTrackValue: (t: Track) => string;
  setTrackValue: (t: Track, v: string) => void;
  setUpdateValue: (u: TrackUpdate, t: Track) => void;
  validate: (v: string, t: Track) => boolean;
}

export const EDIT_TRACK_FIELDS: FieldDefinition[] = [
  {
    name: "name",
    label: "Name",
    getDisplayTrackValue: (t: Track) => t.name,
    setTrackValue: (t: Track, v: string) => (t.name = v),
    setUpdateValue: (u: TrackUpdate, t: Track) => (u.name = t.name),
    validate: ValidRequiredField,
  },
  {
    name: "artist",
    label: "Artist",
    getDisplayTrackValue: (t: Track) => t.artistName,
    setTrackValue: (t: Track, v: string) => (t.artistName = v),
    setUpdateValue: (u: TrackUpdate, t: Track) => (u.artist = t.artistName),
    validate: ValidRequiredField,
  },
  {
    name: "album",
    label: "Album",
    getDisplayTrackValue: (t: Track) => t.albumName,
    setTrackValue: (t: Track, v: string) => (t.albumName = v),
    setUpdateValue: (u: TrackUpdate, t: Track) => (u.album = t.albumName),
    validate: ValidOptionalField,
  },
  {
    name: "albumArtist",
    label: "Album Artist",
    getDisplayTrackValue: (t: Track) => t.albumArtistName,
    setTrackValue: (t: Track, v: string) => (t.albumArtistName = v),
    setUpdateValue: (u: TrackUpdate, t: Track) =>
      (u.albumArtist = t.albumArtistName),
    validate: ValidOptionalField,
  },
  {
    name: "genre",
    label: "Genre",
    getDisplayTrackValue: (t: Track) => t.genre,
    setTrackValue: (t: Track, v: string) => (t.genre = v),
    setUpdateValue: (u: TrackUpdate, t: Track) => (u.genre = t.genre),
    validate: ValidRequiredField,
  },
  {
    name: "year",
    label: "Year",
    getDisplayTrackValue: (t: Track) => t.year.toString(),
    setTrackValue: (t: Track, v: string) => (t.year = parseInt(v)),
    setUpdateValue: (u: TrackUpdate, t: Track) => (u.year = t.year),
    validate: ValidYear,
  },
  {
    name: "start",
    label: "Start",
    getDisplayTrackValue: (t: Track) =>
      FormatPlaybackPositionWithMillis(t.start),
    setTrackValue: (t: Track, v: string) =>
      (t.start = UnformatPlaybackPositionWithMillis(v)),
    setUpdateValue: (u: TrackUpdate, t: Track) => (u.start = t.start),
    validate: ValidPlaybackPosition,
  },
  {
    name: "finish",
    label: "Finish",
    getDisplayTrackValue: (t: Track) =>
      FormatPlaybackPositionWithMillis(t.finish),
    setTrackValue: (t: Track, v: string) =>
      (t.finish = UnformatPlaybackPositionWithMillis(v)),
    setUpdateValue: (u: TrackUpdate, t: Track) => (u.finish = t.finish),
    validate: ValidPlaybackPosition,
  },
];
