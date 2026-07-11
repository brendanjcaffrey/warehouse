// ratings are shown as five stars with half steps, like itunes
const STAR_COUNT = 5;

// the half-star value for a horizontal position across the rating control,
// mirroring the ios control: each tenth of the width is another half star
export function starsAtFraction(fraction: number): number {
  const halves = Math.ceil(fraction * STAR_COUNT * 2);
  return Math.min(STAR_COUNT, Math.max(0.5, halves / 2));
}
