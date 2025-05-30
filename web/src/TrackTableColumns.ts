import { Track } from "./Library";
import { RenderRating } from "./RenderRating";
import { IconWidths } from "./MeasureIconWidths";
import { NUM_ICONS } from "./RenderRating";
import { CELL_HORIZONTAL_PADDING_TOTAL } from "./TrackTableConstants";
import { StringKeys } from "./Util";

export type DisplayedTrackKeys = Pick<
  Track,
  | "name"
  | "duration"
  | "artistName"
  | "albumName"
  | "genre"
  | "year"
  | "playCount"
  | "rating"
>;

type SortKey = keyof Track;

export const FILTER_KEYS: StringKeys<Track>[] = [
  "name",
  "artistName",
  "albumName",
  "genre",
];

export interface Column {
  id: keyof DisplayedTrackKeys;
  label: string;
  render: (track: Track) => JSX.Element | string;
  calculateSizeByRendering: boolean;
  canHaveNowPlayingIcon: boolean;
  sortKeys: SortKey[];
}

export const COLUMNS: Column[] = [
  {
    id: "name",
    label: "Name",
    render: (track: Track) => track.name,
    calculateSizeByRendering: true,
    canHaveNowPlayingIcon: true,
    sortKeys: ["sortName"],
  },
  {
    id: "duration",
    label: "Time",
    render: (track: Track) => {
      const minutes = Math.floor(track.duration / 60);
      const seconds = track.duration % 60;
      return `${minutes}:${seconds.toFixed(0).padStart(2, "0")}`;
    },
    calculateSizeByRendering: true,
    canHaveNowPlayingIcon: false,
    sortKeys: ["duration"],
  },
  {
    id: "artistName",
    label: "Artist",
    render: (track: Track) => track.artistName,
    calculateSizeByRendering: true,
    canHaveNowPlayingIcon: false,
    sortKeys: ["artistSortName"],
  },
  {
    id: "albumName",
    label: "Album",
    render: (track: Track) => track.albumName,
    calculateSizeByRendering: true,
    canHaveNowPlayingIcon: false,
    sortKeys: [
      "albumArtistSortName",
      "year",
      "albumSortName",
      "discNumber",
      "trackNumber",
    ],
  },
  {
    id: "genre",
    label: "Genre",
    render: (track: Track) => track.genre,
    calculateSizeByRendering: true,
    canHaveNowPlayingIcon: false,
    sortKeys: ["genre"],
  },
  {
    id: "year",
    label: "Year",
    render: (track: Track) => (track.year !== 0 ? track.year.toString() : ""),
    calculateSizeByRendering: true,
    canHaveNowPlayingIcon: false,
    sortKeys: ["year"],
  },
  {
    id: "playCount",
    label: "Plays",
    render: (track: Track) => track.playCount.toString(),
    calculateSizeByRendering: true,
    canHaveNowPlayingIcon: false,
    sortKeys: ["playCount"],
  },
  {
    id: "rating",
    label: "Rating",
    render: RenderRating,
    calculateSizeByRendering: false,
    canHaveNowPlayingIcon: false,
    sortKeys: ["rating"],
  },
];

export const RATING_COLUMN_INDEX = COLUMNS.findIndex(
  (column) => column.id === "rating"
);

export function GetColumnWidths(
  tracks: Track[],
  iconWidths: IconWidths
): number[] {
  const widths = COLUMNS.map(() => 0);
  widths[RATING_COLUMN_INDEX] =
    // add an extra half padding here so the scroll bar doesn't overlap with the right most star
    iconWidths.star * NUM_ICONS + CELL_HORIZONTAL_PADDING_TOTAL * 1.5;

  const canvas = document.createElement("canvas");
  const context = canvas.getContext("2d");
  if (!context) {
    return widths;
  }

  // start with the header cell width with sort arrow
  const computedStyle = window.getComputedStyle(document.body);
  context.font = `bold ${computedStyle.font}`;
  for (const [index, column] of COLUMNS.entries()) {
    if (!column.calculateSizeByRendering) {
      continue;
    }
    const width = context.measureText(column.label).width;
    widths[index] =
      width + iconWidths.upwardArrow + CELL_HORIZONTAL_PADDING_TOTAL;
  }

  context.font = computedStyle.font;
  for (const track of tracks) {
    for (const [index, column] of COLUMNS.entries()) {
      if (!column.calculateSizeByRendering) {
        continue;
      }
      const rendered = column.render(track);
      if (typeof rendered === "string") {
        let width =
          context.measureText(rendered).width + CELL_HORIZONTAL_PADDING_TOTAL;
        if (column.canHaveNowPlayingIcon) {
          width += iconWidths.volumeUp;
        }
        widths[index] = Math.max(widths[index], width);
      }
    }
  }
  return widths;
}
