import { Track } from "./Library";
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
  getApiTrackValue: ((t: Track) => string) | undefined;
  setTrackValue: (t: Track, v: string) => void;
  validate: (v: string, t: Track) => boolean;
}

export const EDIT_TRACK_FIELDS: FieldDefinition[] = [
  {
    name: "name",
    label: "Name",
    getDisplayTrackValue: (t: Track) => t.name,
    getApiTrackValue: undefined,
    setTrackValue: (t: Track, v: string) => (t.name = v),
    validate: ValidRequiredField,
  },
  {
    name: "artist",
    label: "Artist",
    getDisplayTrackValue: (t: Track) => t.artistName,
    getApiTrackValue: undefined,
    setTrackValue: (t: Track, v: string) => (t.artistName = v),
    validate: ValidRequiredField,
  },
  {
    name: "album",
    label: "Album",
    getDisplayTrackValue: (t: Track) => t.albumName,
    getApiTrackValue: undefined,
    setTrackValue: (t: Track, v: string) => (t.albumName = v),
    validate: ValidOptionalField,
  },
  {
    name: "albumArtist",
    label: "Album Artist",
    getDisplayTrackValue: (t: Track) => t.albumArtistName,
    getApiTrackValue: undefined,
    setTrackValue: (t: Track, v: string) => (t.albumArtistName = v),
    validate: ValidOptionalField,
  },
  {
    name: "genre",
    label: "Genre",
    getDisplayTrackValue: (t: Track) => t.genre,
    getApiTrackValue: undefined,
    setTrackValue: (t: Track, v: string) => (t.genre = v),
    validate: ValidRequiredField,
  },
  {
    name: "year",
    label: "Year",
    getDisplayTrackValue: (t: Track) => t.year.toString(),
    getApiTrackValue: undefined,
    setTrackValue: (t: Track, v: string) => (t.year = parseInt(v)),
    validate: ValidYear,
  },
  {
    name: "start",
    label: "Start",
    getDisplayTrackValue: (t: Track) =>
      FormatPlaybackPositionWithMillis(t.start),
    getApiTrackValue: (t: Track) => t.start.toFixed(3),
    setTrackValue: (t: Track, v: string) =>
      (t.start = UnformatPlaybackPositionWithMillis(v)),
    validate: ValidPlaybackPosition,
  },
  {
    name: "finish",
    label: "Finish",
    getDisplayTrackValue: (t: Track) =>
      FormatPlaybackPositionWithMillis(t.finish),
    getApiTrackValue: (t: Track) => t.finish.toFixed(3),
    setTrackValue: (t: Track, v: string) =>
      (t.finish = UnformatPlaybackPositionWithMillis(v)),
    validate: ValidPlaybackPosition,
  },
];
