import { ReactNode } from "react";
import { afterEach, beforeEach, expect, test, vi } from "vitest";
import { cleanup, fireEvent, render } from "@testing-library/react";
import { Provider, createStore } from "jotai";
import Controls from "../src/Controls";
import { useDisplayedTracks } from "../src/DisplayedTracks";
import type { Track } from "../src/Library";

const { currentPlayer } = vi.hoisted(() => ({
  currentPlayer: {
    queue: { isEmpty: true },
    playTracksInOrder: vi.fn(),
    playPause: vi.fn(),
    prev: vi.fn(),
    next: vi.fn(),
    setShuffled: vi.fn(),
    setVolume: vi.fn(),
  },
}));

vi.mock("../src/Player", () => ({ player: () => currentPlayer }));
vi.mock("@restart/hooks/useBreakpoint", () => ({ default: () => false }));

function Display({ source, tracks }: { source: string; tracks: Track[] }) {
  useDisplayedTracks(source, tracks);
  return null;
}

function track(id: string): Track {
  return { id } as Track;
}

function withStore() {
  const store = createStore();
  const wrapper = ({ children }: { children: ReactNode }) => (
    <Provider store={store}>{children}</Provider>
  );
  return { wrapper };
}

beforeEach(() => {
  currentPlayer.queue.isEmpty = true;
  vi.clearAllMocks();
});

afterEach(() => cleanup());

test("main play starts the displayed tracks in their displayed order", () => {
  const first = track("filtered-second");
  const second = track("filtered-first");
  const { wrapper } = withStore();
  const { container, rerender } = render(
    <>
      <Controls />
      <Display source="playlist:one" tracks={[second, first]} />
    </>,
    { wrapper }
  );
  rerender(
    <>
      <Controls />
      <Display source="playlist:one" tracks={[first, second]} />
    </>
  );

  fireEvent.click(container.querySelectorAll("button")[1]);

  expect(currentPlayer.playTracksInOrder).toHaveBeenCalledWith(
    "playlist:one",
    [first, second],
    0
  );
  expect(currentPlayer.playPause).not.toHaveBeenCalled();
});

test("main play keeps pause and resume behavior with an existing queue", () => {
  currentPlayer.queue.isEmpty = false;
  const { wrapper } = withStore();
  const { container } = render(
    <>
      <Controls />
      <Display source="library" tracks={[track("t1")]} />
    </>,
    { wrapper }
  );

  fireEvent.click(container.querySelectorAll("button")[1]);

  expect(currentPlayer.playPause).toHaveBeenCalledOnce();
  expect(currentPlayer.playTracksInOrder).not.toHaveBeenCalled();
});

test("main play does nothing when the current view has no tracks", () => {
  const { wrapper } = withStore();
  const { container } = render(
    <>
      <Controls />
      <Display source="library" tracks={[]} />
    </>,
    { wrapper }
  );

  fireEvent.click(container.querySelectorAll("button")[1]);

  expect(currentPlayer.playTracksInOrder).not.toHaveBeenCalled();
  expect(currentPlayer.playPause).not.toHaveBeenCalled();
});

test("leaving a view clears its displayed tracks", () => {
  const { wrapper } = withStore();
  const { container, rerender } = render(
    <>
      <Controls />
      <Display source="library" tracks={[track("t1")]} />
    </>,
    { wrapper }
  );
  rerender(<Controls />);

  fireEvent.click(container.querySelectorAll("button")[1]);

  expect(currentPlayer.playTracksInOrder).not.toHaveBeenCalled();
});
