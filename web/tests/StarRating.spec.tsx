import { afterEach, expect, test, vi } from "vitest";
import { cleanup, fireEvent, render } from "@testing-library/react";
import StarRating from "../src/StarRating";
import { starsAtFraction } from "../src/StarRatingPosition";

afterEach(() => cleanup());

test("starsAtFraction maps a position to a half-star value like ios", () => {
  expect(starsAtFraction(0)).toBe(0.5);
  expect(starsAtFraction(0.1)).toBe(0.5);
  expect(starsAtFraction(0.11)).toBe(1);
  expect(starsAtFraction(0.5)).toBe(2.5);
  expect(starsAtFraction(1)).toBe(5);
  expect(starsAtFraction(1.5)).toBe(5);
});

test("a read-only rating is not interactive", () => {
  const { container } = render(<StarRating rating={60} />);
  expect(container.querySelector('[role="slider"]')).toBeNull();
});

test("clicking an interactive rating reports the value in 0-100", () => {
  const onRate = vi.fn();
  const { getByRole } = render(<StarRating rating={0} onRate={onRate} />);
  const slider = getByRole("slider");
  vi.spyOn(slider, "getBoundingClientRect").mockReturnValue({
    left: 0,
    width: 100,
  } as DOMRect);

  fireEvent.click(slider, { clientX: 50 });
  expect(onRate).toHaveBeenCalledWith(50);

  fireEvent.click(slider, { clientX: 100 });
  expect(onRate).toHaveBeenLastCalledWith(100);
});
