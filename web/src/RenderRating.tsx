import { useState } from "react";
import { Rating } from "@mui/material";
import { StarRounded, StarBorderRounded } from "@mui/icons-material";
import { store, trackUpdatedFnAtom } from "./State";
import library, { Track } from "./Library";
import { updatePersister } from "./UpdatePersister";

export const NUM_ICONS = 5;

export function RenderRating(track: Track): JSX.Element {
  const [rating, setRating] = useState(track.rating / 10);

  return (
    <Rating
      value={rating}
      precision={0.5}
      onClick={(event) => {
        // prevent the row from being selected when clicking on the rating
        event.stopPropagation();
      }}
      onChange={async (_, newValue) => {
        if (!newValue) {
          return;
        }
        // update the UI immediately
        setRating(newValue);

        // then persist the change
        const updatedTrack = await library().getTrack(track.id);
        if (!updatedTrack) {
          return;
        }
        updatedTrack.rating = newValue * 10;
        await library().putTrack(updatedTrack);
        store.get(trackUpdatedFnAtom).fn(updatedTrack);
        updatePersister().updateRating(track.id, updatedTrack.rating);
      }}
      icon={<StarRounded fontSize="small" />}
      emptyIcon={<StarBorderRounded fontSize="small" />}
    />
  );
}
