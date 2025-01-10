import { StarRounded, StarBorderRounded, StarHalf } from "@mui/icons-material";
import { store, trackUpdatedFnAtom } from "./State";
import library, { Track } from "./Library";
import { updatePersister } from "./UpdatePersister";
import {
  CELL_HORIZONTAL_PADDING_SIDE,
  CELL_HORIZONTAL_PADDING_TOTAL,
} from "./TrackTableConstants";

export const NUM_ICONS = 5;

export function RenderRating(track: Track): JSX.Element {
  const updateRating = async (event: React.MouseEvent<HTMLDivElement>) => {
    let rating: number | undefined = undefined;
    const target = event.target as HTMLElement;
    const icon = target.closest("svg");
    if (!icon) {
      // we clicked on the div, not the icon (note that this can be above or below the icon)
      const rect = target.getBoundingClientRect();
      const clickX = event.clientX;
      const clickOffset = clickX - rect.left;
      if (clickOffset <= CELL_HORIZONTAL_PADDING_SIDE) {
        rating = 0;
      } else if (clickOffset >= rect.width - CELL_HORIZONTAL_PADDING_TOTAL) {
        rating = 100;
      } else {
        const perentOfIcons =
          (clickOffset - CELL_HORIZONTAL_PADDING_SIDE) /
          (rect.width - CELL_HORIZONTAL_PADDING_TOTAL);
        rating = Math.floor(perentOfIcons * 10) * 10 + 10;
      }
    } else {
      const parent = icon.parentNode;
      if (!parent) {
        return;
      }

      const children = Array.from(parent.children);
      const index = children.indexOf(icon);

      const rect = icon.getBoundingClientRect();
      const clickX = event.clientX;
      const isLeftHalf = clickX < rect.left + rect.width / 2;

      rating = (index + 1) * 20 + (isLeftHalf ? -10 : 0);
    }

    const updatedTrack = await library().getTrack(track.id);
    if (!updatedTrack) {
      return;
    }
    updatedTrack.rating = rating;
    await library().putTrack(updatedTrack);
    store.get(trackUpdatedFnAtom).fn(updatedTrack);
    updatePersister().updateRating(track.id, rating);
  };

  const clampedRating = Math.floor(track.rating / 10);
  const icons = [
    clampedRating >= 2 ? StarRounded : StarBorderRounded,
    clampedRating >= 4 ? StarRounded : StarBorderRounded,
    clampedRating >= 6 ? StarRounded : StarBorderRounded,
    clampedRating >= 8 ? StarRounded : StarBorderRounded,
    clampedRating >= 10 ? StarRounded : StarBorderRounded,
  ];
  if (clampedRating % 2 === 1) {
    icons[Math.floor(clampedRating / 2)] = StarHalf;
  }

  return (
    <div
      onClick={updateRating}
      style={{ padding: `0 ${CELL_HORIZONTAL_PADDING_SIDE}px` }}
    >
      {icons.map((Icon, index) => (
        <Icon key={index} fontSize="small" />
      ))}
    </div>
  );
}
