import { ReactNode } from "react";
import { Track } from "./Library";
import type { SortDirection } from "./TrackSort";
import StarRating from "./StarRating";
import { FormatPlaybackPosition } from "./PlaybackPositionFormatters";

export type ColumnType = "text" | "number";

export interface TrackColumn {
  id: string;
  header: string;
  // css grid track sizing so the header and body rows share one template and
  // stay aligned column for column
  width: string;
  align: "start" | "end";
  type: ColumnType;
  // the direction the first sort click applies, so a column can lead with desc;
  // defaults to asc when unset
  defaultDirection?: SortDirection;
  // whether the header offers a filter box; defaults to true when unset
  filterable?: boolean;
  // the comparable value sorting works against; text columns sort on their
  // sort-name variant so "the beatles" files under "beatles"
  value: (track: Track) => string | number;
  // display text a text column filters against, so people match what they see
  // rather than the sort name; number columns filter on their value
  text?: (track: Track) => string;
  render: (track: Track) => ReactNode;
}

// blank rather than "0" for the numeric columns itunes leaves empty
function numberOrBlank(value: number): string {
  return value > 0 ? String(value) : "";
}

// absolute date-only, locale medium ("Jul 3, 2026"); blank for the epoch-0
// sentinel a track with no added date carries
const dateAddedFormat = new Intl.DateTimeFormat(undefined, {
  dateStyle: "medium",
});
export function formatDateAdded(epochSeconds: number): string {
  return epochSeconds > 0
    ? dateAddedFormat.format(new Date(epochSeconds * 1000))
    : "";
}

// the itunes-standard column set; adjust freely, everything downstream keys off
// the column id
export const TRACK_COLUMNS: TrackColumn[] = [
  {
    id: "name",
    header: "name",
    width: "minmax(180px, 2fr)",
    align: "start",
    type: "text",
    // the sort-name variants are omitted when they match the display name to save
    // space, so fall back to it rather than sorting the blanks to the top
    value: (track) => track.sortName || track.name,
    text: (track) => track.name,
    render: (track) => track.name,
  },
  {
    id: "artist",
    header: "artist",
    width: "minmax(140px, 1.5fr)",
    align: "start",
    type: "text",
    value: (track) => track.artistSortName || track.artistName,
    text: (track) => track.artistName,
    render: (track) => track.artistName,
  },
  {
    id: "album",
    header: "album",
    width: "minmax(140px, 1.5fr)",
    align: "start",
    type: "text",
    value: (track) => track.albumSortName || track.albumName,
    text: (track) => track.albumName,
    render: (track) => track.albumName,
  },
  {
    id: "genre",
    header: "genre",
    width: "minmax(100px, 1fr)",
    align: "start",
    type: "text",
    value: (track) => track.genre,
    render: (track) => track.genre,
  },
  {
    id: "year",
    header: "year",
    width: "72px",
    align: "end",
    type: "number",
    value: (track) => track.year,
    render: (track) => numberOrBlank(track.year),
  },
  {
    id: "duration",
    header: "time",
    width: "80px",
    align: "end",
    type: "number",
    value: (track) => track.duration,
    render: (track) => FormatPlaybackPosition(track.duration),
  },
  {
    id: "rating",
    header: "rating",
    width: "104px",
    align: "end",
    type: "number",
    value: (track) => track.rating,
    render: (track) => <StarRating rating={track.rating} />,
  },
  {
    id: "plays",
    header: "plays",
    width: "72px",
    align: "end",
    type: "number",
    value: (track) => track.playCount,
    render: (track) => numberOrBlank(track.playCount),
  },
  {
    id: "added",
    header: "added",
    width: "110px",
    align: "end",
    type: "number",
    // newest-first on the first click; a raw-epoch filter box would be unusable
    defaultDirection: "desc",
    filterable: false,
    value: (track) => track.addedDate,
    render: (track) => formatDateAdded(track.addedDate),
  },
];
