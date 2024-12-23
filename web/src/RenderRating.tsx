import { StarRounded, StarBorderRounded, StarHalf } from "@mui/icons-material";
import { Track } from "./Library";

export const NUM_ICONS = 5;

export function RenderRating(track: Track): JSX.Element {
  switch (Math.floor(track.rating / 10)) {
    case 0:
      return (
        <>
          <StarBorderRounded fontSize="small" />
          <StarBorderRounded fontSize="small" />
          <StarBorderRounded fontSize="small" />
          <StarBorderRounded fontSize="small" />
          <StarBorderRounded fontSize="small" />
        </>
      );
    case 1:
      return (
        <>
          <StarHalf fontSize="small" />
          <StarBorderRounded fontSize="small" />
          <StarBorderRounded fontSize="small" />
          <StarBorderRounded fontSize="small" />
          <StarBorderRounded fontSize="small" />
        </>
      );
    case 2:
      return (
        <>
          <StarRounded fontSize="small" />
          <StarBorderRounded fontSize="small" />
          <StarBorderRounded fontSize="small" />
          <StarBorderRounded fontSize="small" />
          <StarBorderRounded fontSize="small" />
        </>
      );
    case 3:
      return (
        <>
          <StarRounded fontSize="small" />
          <StarHalf fontSize="small" />
          <StarBorderRounded fontSize="small" />
          <StarBorderRounded fontSize="small" />
          <StarBorderRounded fontSize="small" />
        </>
      );
    case 4:
      return (
        <>
          <StarRounded fontSize="small" />
          <StarRounded fontSize="small" />
          <StarBorderRounded fontSize="small" />
          <StarBorderRounded fontSize="small" />
          <StarBorderRounded fontSize="small" />
        </>
      );
    case 5:
      return (
        <>
          <StarRounded fontSize="small" />
          <StarRounded fontSize="small" />
          <StarHalf fontSize="small" />
          <StarBorderRounded fontSize="small" />
          <StarBorderRounded fontSize="small" />
        </>
      );
    case 6:
      return (
        <>
          <StarRounded fontSize="small" />
          <StarRounded fontSize="small" />
          <StarRounded fontSize="small" />
          <StarBorderRounded fontSize="small" />
          <StarBorderRounded fontSize="small" />
        </>
      );
    case 7:
      return (
        <>
          <StarRounded fontSize="small" />
          <StarRounded fontSize="small" />
          <StarRounded fontSize="small" />
          <StarHalf fontSize="small" />
          <StarBorderRounded fontSize="small" />
        </>
      );
    case 8:
      return (
        <>
          <StarRounded fontSize="small" />
          <StarRounded fontSize="small" />
          <StarRounded fontSize="small" />
          <StarRounded fontSize="small" />
          <StarBorderRounded fontSize="small" />
        </>
      );
    case 9:
      return (
        <>
          <StarRounded fontSize="small" />
          <StarRounded fontSize="small" />
          <StarRounded fontSize="small" />
          <StarRounded fontSize="small" />
          <StarHalf fontSize="small" />
        </>
      );
    case 10:
      return (
        <>
          <StarRounded fontSize="small" />
          <StarRounded fontSize="small" />
          <StarRounded fontSize="small" />
          <StarRounded fontSize="small" />
          <StarRounded fontSize="small" />
        </>
      );
  }

  return <></>;
}
