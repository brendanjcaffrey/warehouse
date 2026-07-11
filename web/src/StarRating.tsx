import { Star, StarHalf, StarFill } from "react-bootstrap-icons";

// ratings are stored 0-100 but shown as five stars with half steps, like itunes
const RATING_PER_STAR = 20;
const STAR_SLOTS = [1, 2, 3, 4, 5];

interface StarRatingProps {
  rating: number;
  size?: number;
}

// read-only star display; always shows five slots, filling empties with outlines
function StarRating({ rating, size = 12 }: StarRatingProps) {
  const stars = rating / RATING_PER_STAR;
  return (
    <span className="text-warning d-inline-flex gap-1">
      {STAR_SLOTS.map((slot) => {
        if (stars >= slot) {
          return <StarFill key={slot} size={size} />;
        }
        if (stars >= slot - 0.5) {
          return <StarHalf key={slot} size={size} />;
        }
        return <Star key={slot} size={size} />;
      })}
    </span>
  );
}

export default StarRating;
