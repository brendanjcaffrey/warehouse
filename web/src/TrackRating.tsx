import library, { Track } from "./Library";
import StarRating from "./StarRating";
import { rateTrack } from "./TrackEdit";

// the star rating shown in the track lists: interactive (hover to preview, click
// to set) when the library allows track changes, otherwise a read-only display
function TrackRating({ track, size }: { track: Track; size?: number }) {
  if (!library().getTrackUserChanges()) {
    return <StarRating rating={track.rating} size={size} />;
  }
  return (
    <StarRating
      rating={track.rating}
      size={size}
      onRate={(rating) => rateTrack(track, rating)}
    />
  );
}

export default TrackRating;
