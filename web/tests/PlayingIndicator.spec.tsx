import { ReactNode } from "react";
import { afterEach, expect, test } from "vitest";
import { cleanup, render } from "@testing-library/react";
import { Provider, createStore } from "jotai";
import { playingAtom, playingTrackAtom } from "../src/State";
import PlayingIndicator from "../src/PlayingIndicator";
import { Track } from "../src/Library";

afterEach(() => cleanup());

// only the id matters to the indicator
function track(id: string): Track {
  return { id } as Track;
}

// a store with `trackId` loaded into the player, playing or paused
function withStore(trackId: string | undefined, playing: boolean) {
  const store = createStore();
  store.set(playingAtom, playing);
  if (trackId) {
    store.set(playingTrackAtom, {
      track: track(trackId),
      playlistId: "library",
      playlistOffset: 0,
    });
  }
  const wrapper = ({ children }: { children: ReactNode }) => (
    <Provider store={store}>{children}</Provider>
  );
  return { store, wrapper };
}

test("the playing track is marked and the others are not", () => {
  const { wrapper } = withStore("t2", true);
  const { container } = render(
    <>
      <PlayingIndicator trackId="t1" />
      <PlayingIndicator trackId="t2" />
      <PlayingIndicator trackId="t3" />
    </>,
    { wrapper }
  );
  const marks = container.querySelectorAll('[data-testid="playing-indicator"]');
  expect(marks).toHaveLength(1);
  expect(marks[0].getAttribute("aria-label")).toBe("playing");
});

test("the mark reads as paused while playback is paused", () => {
  const { wrapper } = withStore("t1", false);
  const { container } = render(<PlayingIndicator trackId="t1" />, { wrapper });
  expect(
    container
      .querySelector('[data-testid="playing-indicator"]')
      ?.getAttribute("aria-label")
  ).toBe("paused");
});

test("nothing is marked when no track is loaded", () => {
  const { wrapper } = withStore(undefined, false);
  const { container } = render(<PlayingIndicator trackId="t1" />, { wrapper });
  expect(
    container.querySelector('[data-testid="playing-indicator"]')
  ).toBeNull();
});
