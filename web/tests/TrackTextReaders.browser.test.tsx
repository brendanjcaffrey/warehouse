import "bootstrap/dist/css/bootstrap.min.css";
import { page } from "vitest/browser";
import { afterEach, beforeEach, expect, test, vi } from "vitest";
import {
  act,
  cleanup,
  fireEvent,
  render,
  waitFor,
  within,
} from "@testing-library/react";
import { Provider } from "jotai";
import { MemoryRouter } from "react-router-dom";
import library, { Track } from "../src/Library";
import NowPlaying from "../src/NowPlaying";
import { useTrackContextMenu } from "../src/TrackContextMenu";
import { player } from "../src/Player";
import { store } from "../src/State";
import TrackTextReader from "../src/TrackTextReader";

vi.mock("../src/DownloadWorker", () => ({
  DownloadWorker: {
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    postMessage: vi.fn(),
  },
}));
vi.mock("../src/Files", () => ({
  files: () => ({ tryGetFileURL: async () => null }),
}));

const text =
  Array.from(
    { length: 150 },
    (_, index) => `line ${index}: café 第二行 🎶`
  ).join("\n") +
  "\n" +
  "longword".repeat(100);
const first: Track = {
  id: "reader-first",
  name: "First song",
  sortName: "first song",
  artistName: "Artist",
  artistSortName: "artist",
  albumArtistName: "Artist",
  albumArtistSortName: "artist",
  albumSortName: "album",
  genre: "Rock",
  year: 2026,
  trackNumber: 1,
  discNumber: 1,
  playCount: 0,
  rating: 0,
  addedDate: 0,
  albumName: "Album",
  playlistIds: [],
  lyrics: text,
  comments: text,
  duration: 200,
  start: 0,
  finish: 200,
  musicFilename: "reader-first.mp3",
  artworkFilename: null,
};
const second = {
  ...first,
  id: "reader-second",
  name: "Second song",
  lyrics: text + "\nsecond lyrics",
};

function Menu() {
  const menu = useTrackContextMenu();
  return (
    <>
      <button onClick={(event) => menu.openMenu(event, first)}>
        Selected track menu
      </button>
      {menu.element}
    </>
  );
}

beforeEach(async () => {
  await page.viewport(1280, 800);
  localStorage.setItem("trackUserChanges", "true");
  await new Promise<void>((resolve) =>
    library().setInitializedListener(resolve)
  );
  await library().putTrack(first);
  await library().putTrack(second);
  await player().reset();
  player().setAudioRef({
    src: "",
    currentTime: 0,
    volume: 1,
    play: vi.fn().mockResolvedValue(undefined),
    pause: vi.fn(),
  } as unknown as HTMLAudioElement);
  await player().playTracks("library", [first, second], 0);
  render(
    <Provider store={store}>
      <MemoryRouter>
        <NowPlaying />
        <Menu />
      </MemoryRouter>
    </Provider>
  );
});
afterEach(() => cleanup());

function expectFits(reader: HTMLElement) {
  const rect = reader.querySelector(".modal-content")!.getBoundingClientRect();
  expect(rect.left).toBeGreaterThanOrEqual(0);
  expect(rect.right).toBeLessThanOrEqual(window.innerWidth);
  expect(rect.top).toBeGreaterThanOrEqual(0);
  expect(rect.bottom).toBeLessThanOrEqual(window.innerHeight);
  const body = within(reader).getByRole("region");
  expect(body.scrollHeight).toBeGreaterThan(body.clientHeight);
  expect(body.scrollWidth).toBeLessThanOrEqual(body.clientWidth);
}

test.each([
  ["LF", "\n"],
  ["CRLF", "\r\n"],
  ["CR", "\r"],
])(
  "readers preserve line and stanza breaks with %s newlines",
  async (_, newline) => {
    const value = ["  first line", "", "第二行 🎶", "<plain text>"].join(
      newline
    );
    for (const field of ["lyrics", "comments"] as const) {
      const view = render(
        <TrackTextReader
          track={{ ...first, [field]: value }}
          field={field}
          onClose={vi.fn()}
        />
      );
      const body = await waitFor(() =>
        within(document.body).getByRole("region", {
          name: `${field === "lyrics" ? "Lyrics" : "Comments"} text`,
        })
      );
      const topOf = (line: string) => {
        const offset = body.textContent!.indexOf(line);
        const range = document.createRange();
        range.setStart(body.firstChild!, offset);
        range.setEnd(body.firstChild!, offset + line.length);
        return range.getBoundingClientRect().top;
      };
      const lineHeight = parseFloat(getComputedStyle(body).lineHeight);
      expect(topOf("第二行 🎶") - topOf("first line")).toBeCloseTo(
        lineHeight * 2
      );
      expect(topOf("<plain text>") - topOf("第二行 🎶")).toBeCloseTo(
        lineHeight
      );
      view.unmount();
    }
  }
);

test.each([1280, 390])(
  "Now Playing at width %s resets real scroll on advance and keeps the header and Edit visible",
  async (width) => {
    await page.viewport(width, 844);
    fireEvent.click(document.querySelector('button[aria-label="Lyrics"]')!);
    const reader = await waitFor(() =>
      within(document.body).getByRole("dialog", { name: "Lyrics" })
    );
    await waitFor(() => expectFits(reader));
    let body = within(reader).getByRole("region", { name: "Lyrics text" });
    body.scrollTop = 700;
    expect(body.scrollTop).toBeGreaterThan(0);
    expect(
      within(reader)
        .getByRole("button", { name: "Edit" })
        .getBoundingClientRect().bottom
    ).toBeLessThanOrEqual(window.innerHeight);
    await act(() => player().next());
    await waitFor(() =>
      expect(within(reader).getByText("Second song")).toBeTruthy()
    );
    body = within(reader).getByRole("region", { name: "Lyrics text" });
    expect(body.scrollTop).toBe(0);
    expect(body.textContent).toBe(second.lyrics);
    expectFits(reader);
  }
);

test.each(["Lyrics", "Comments"])(
  "track-menu %s preserves actual scroll and selected text when playback advances",
  async (field) => {
    fireEvent.click(
      within(document.body).getByRole("button", { name: "Selected track menu" })
    );
    fireEvent.click(
      within(document.body).getByRole("menuitem", { name: field })
    );
    const reader = await waitFor(() =>
      within(document.body).getByRole("dialog", { name: field })
    );
    await waitFor(() => expectFits(reader));
    const body = within(reader).getByRole("region", { name: `${field} text` });
    body.scrollTop = 600;
    const position = body.scrollTop;
    expect(position).toBeGreaterThan(0);
    await act(() => player().next());
    expect(body.scrollTop).toBe(position);
    expect(body.textContent).toBe(text);
    expect(within(reader).getByText("First song")).toBeTruthy();
  }
);
