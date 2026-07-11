import { useRef, useState } from "react";
import { Star, StarHalf, StarFill } from "react-bootstrap-icons";
import { starsAtFraction } from "./StarRatingPosition";

// ratings are stored 0-100 but shown as five stars with half steps, like itunes
const RATING_PER_STAR = 20;
const STAR_COUNT = 5;
const STAR_SLOTS = [1, 2, 3, 4, 5];

interface StarRatingProps {
  rating: number;
  size?: number;
  // when given, the control turns interactive: hovering previews the value and
  // clicking sets it (reported back in 0-100). omit it for a read-only display
  onRate?: (rating: number) => void;
}

// five star slots, always shown, filling empties with outlines. read-only by
// default; with onRate it previews on hover and sets the rating on click
function StarRating({ rating, size = 12, onRate }: StarRatingProps) {
  const ref = useRef<HTMLSpanElement>(null);
  const [hoverStars, setHoverStars] = useState<number | null>(null);
  const interactive = onRate !== undefined;
  const stars = (interactive ? hoverStars : null) ?? rating / RATING_PER_STAR;

  const starsAtEvent = (event: React.MouseEvent) => {
    const rect = ref.current?.getBoundingClientRect();
    if (!rect || rect.width === 0) {
      return 0;
    }
    return starsAtFraction((event.clientX - rect.left) / rect.width);
  };

  return (
    <span
      ref={ref}
      className="text-warning d-inline-flex gap-1"
      style={interactive ? { cursor: "pointer" } : undefined}
      role={interactive ? "slider" : undefined}
      aria-label={interactive ? "rating" : undefined}
      aria-valuenow={interactive ? stars : undefined}
      aria-valuemin={interactive ? 0 : undefined}
      aria-valuemax={interactive ? STAR_COUNT : undefined}
      onMouseMove={
        interactive ? (event) => setHoverStars(starsAtEvent(event)) : undefined
      }
      onMouseLeave={interactive ? () => setHoverStars(null) : undefined}
      onClick={
        interactive
          ? (event) => {
              event.stopPropagation();
              onRate(starsAtEvent(event) * RATING_PER_STAR);
            }
          : undefined
      }
    >
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
