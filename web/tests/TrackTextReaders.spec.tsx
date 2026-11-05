import "fake-indexeddb/auto";
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
import { updatePersister } from "../src/UpdatePersister";
import { TrackUpdate } from "../src/generated/messages";

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
vi.mock("@restart/hooks/useBreakpoint", () => ({ default: () => false }));

const first: Track = {
  id: "first",
  name: "First song",
  sortName: "first song",
  artistName: "Artist",
  artistSortName: "artist",
  albumArtistName: "Artist",
  albumArtistSortName: "artist",
  albumName: "Album",
  albumSortName: "album",
  genre: "Rock",
  year: 2026,
  duration: 200,
  start: 0,
  finish: 200,
  trackNumber: 1,
  discNumber: 1,
  playCount: 0,
  rating: 0,
  musicFilename: "first.mp3",
  artworkFilename: null,
  addedDate: 0,
  playlistIds: ["library"],
  lyrics: "  first line\n\n第二行 🎶\n",
  comments: "notes\n<plain text> & café",
};
const second: Track = {
  ...first,
  id: "second",
  name: "Second song",
  lyrics: "second lyrics",
  comments: "second comments",
  musicFilename: "second.mp3",
};

function TrackMenu({ track }: { track: Track }) {
  const menu = useTrackContextMenu();
  return (
    <>
      <button onClick={(event) => menu.openMenu(event, track)}>
        Selected track menu
      </button>
      {menu.element}
    </>
  );
}

function app(track: Track = first) {
  return render(
    <Provider store={store}>
      <MemoryRouter>
        <NowPlaying />
        <TrackMenu track={track} />
      </MemoryRouter>
    </Provider>
  );
}

beforeEach(async () => {
  localStorage.clear();
  updatePersister.cache.clear!();
  await player().reset();
  player().setAudioRef({
    src: "",
    currentTime: 0,
    volume: 1,
    play: vi.fn().mockResolvedValue(undefined),
    pause: vi.fn(),
  } as unknown as HTMLAudioElement);
  await new Promise<void>((resolve) =>
    library().setInitializedListener(resolve)
  );
  library().clear();
  await library().getAllTracks();
  await library().getAllPlaylists();
  await library().putMetadata({
    type: "libraryMetadata",
    trackUserChanges: true,
    totalFileSize: 0,
    updateTimeNs: 1,
  });
  await library().putTrack(first);
  await library().putTrack(second);
});
afterEach(async () => {
  cleanup();
  await updatePersister().setAuthToken(null);
});

test.each([
  ["Lyrics", "Selected track menu"],
  ["Comments", "Selected track menu"],
  ["Lyrics", "track menu"],
  ["Comments", "track menu"],
])(
  "%s from %s reads saved multiline text offline and stays pinned during playback",
  async (field, entry) => {
    library.cache.clear!();
    await new Promise<void>((resolve) =>
      library().setInitializedListener(resolve)
    );
    const saved = (await library().getTrack(first.id))!;
    await player().playTracks("library", [first, second], 0);
    const view = app(saved);
    fireEvent.click(view.getByRole("button", { name: entry }));
    fireEvent.click(view.getByRole("menuitem", { name: field }));
    const reader = await view.findByRole("dialog", { name: field });
    expect(within(reader).getByText("First song")).toBeTruthy();
    const text = within(reader).getByRole("region", { name: `${field} text` });
    expect(text.textContent).toBe(
      field === "Lyrics" ? first.lyrics : first.comments
    );
    expect(text.style.whiteSpace).toBe("pre-wrap");
    await act(() => player().next());
    expect(within(reader).getByText("First song")).toBeTruthy();
    expect(text.textContent).toBe(
      field === "Lyrics" ? first.lyrics : first.comments
    );
    expect(view.queryByRole("textbox")).toBeNull();
  }
);

test("Now Playing lyrics follows real playback and opens the shared editor on the displayed track", async () => {
  await player().playTracks("library", [first, second], 0);
  const view = app();
  fireEvent.click(view.getByRole("button", { name: "Lyrics" }));
  let reader = await view.findByRole("dialog", { name: "Lyrics" });
  expect(within(reader).getByText("First song")).toBeTruthy();
  await act(() => player().next());
  reader = view.getByRole("dialog", { name: "Lyrics" });
  expect(within(reader).getByText("Second song")).toBeTruthy();
  expect(
    within(reader).getByRole("region", { name: "Lyrics text" }).textContent
  ).toBe(second.lyrics);
  fireEvent.click(within(reader).getByRole("button", { name: "Edit" }));
  expect(
    ((await view.findByRole("textbox", { name: "Name" })) as HTMLInputElement)
      .value
  ).toBe(second.name);
});

test.each(["Lyrics", "Comments"])(
  "%s editor stays on its original track while playback advances and saves back to its reader",
  async (field) => {
    await player().playTracks("library", [first, second], 0);
    const view = app();
    fireEvent.click(view.getByRole("button", { name: "Selected track menu" }));
    fireEvent.click(view.getByRole("menuitem", { name: field }));
    const reader = await view.findByRole("dialog", { name: field });
    fireEvent.click(within(reader).getByRole("button", { name: "Edit" }));
    const input = await view.findByRole("textbox", { name: field });
    fireEvent.change(input, { target: { value: "changed\n第二行 🎶" } });
    await act(() => player().next());
    expect(
      (view.getByRole("textbox", { name: "Name" }) as HTMLInputElement).value
    ).toBe(first.name);
    fireEvent.click(view.getByRole("button", { name: "save" }));
    const updatedReader = await view.findByRole("dialog", { name: field });
    expect(
      within(updatedReader).getByRole("region", { name: `${field} text` })
        .textContent
    ).toBe("changed\n第二行 🎶");
    const key = field === "Lyrics" ? "lyrics" : "comments";
    expect((await library().getTrack(first.id))![key]).toBe(
      "changed\n第二行 🎶"
    );
    expect(await library().getTrack(second.id)).toEqual(second);
    expect(player().playingTrack?.track).toEqual(second);
    const pending = updatePersister().pendingUpdates;
    expect(pending).toHaveLength(1);
    expect(pending[0]).toMatchObject({ type: "track", trackId: first.id });
    if (pending[0].type === "track")
      expect(pending[0].params.serialize()).toEqual(
        new TrackUpdate({ [key]: "changed\n第二行 🎶" }).serialize()
      );
  }
);

test("Now Playing editor remains on its original track and returns to current lyrics after saving", async () => {
  await player().playTracks("library", [first, second], 0);
  const view = app();
  fireEvent.click(view.getByRole("button", { name: "Lyrics" }));
  fireEvent.click(
    within(await view.findByRole("dialog", { name: "Lyrics" })).getByRole(
      "button",
      { name: "Edit" }
    )
  );
  fireEvent.change(await view.findByRole("textbox", { name: "Lyrics" }), {
    target: { value: "original edited" },
  });
  await act(() => player().next());
  fireEvent.click(view.getByRole("button", { name: "save" }));
  const reader = await view.findByRole("dialog", { name: "Lyrics" });
  expect(within(reader).getByText("Second song")).toBeTruthy();
  expect(
    within(reader).getByRole("region", { name: "Lyrics text" }).textContent
  ).toBe(second.lyrics);
  expect((await library().getTrack(first.id))!.lyrics).toBe("original edited");
});

test("saving the current song updates reader and Now Playing; cancel discards changes", async () => {
  await player().playTracks("library", [first], 0);
  const view = app();
  fireEvent.click(view.getByRole("button", { name: "Lyrics" }));
  fireEvent.click(
    within(await view.findByRole("dialog", { name: "Lyrics" })).getByRole(
      "button",
      { name: "Edit" }
    )
  );
  fireEvent.change(await view.findByRole("textbox", { name: "Name" }), {
    target: { value: "Renamed" },
  });
  fireEvent.change(view.getByRole("textbox", { name: "Lyrics" }), {
    target: { value: "saved\nlyrics" },
  });
  fireEvent.click(view.getByRole("button", { name: "save" }));
  const reader = await view.findByRole("dialog", { name: "Lyrics" });
  expect(within(reader).getByText("Renamed")).toBeTruthy();
  expect(view.getAllByText("Renamed")).toHaveLength(2);
  expect(
    within(reader).getByRole("region", { name: "Lyrics text" }).textContent
  ).toBe("saved\nlyrics");
  expect(player().playingTrack?.track.lyrics).toBe("saved\nlyrics");
  fireEvent.click(within(reader).getByRole("button", { name: "Edit" }));
  fireEvent.change(await view.findByRole("textbox", { name: "Lyrics" }), {
    target: { value: "discarded" },
  });
  fireEvent.click(view.getByRole("button", { name: "cancel" }));
  await waitFor(() =>
    expect(view.getByRole("region", { name: "Lyrics text" }).textContent).toBe(
      "saved\nlyrics"
    )
  );
});

test.each(["Lyrics", "Comments"])(
  "empty and legacy %s stay readable under read-only policy",
  async (field) => {
    const blank = { ...first, lyrics: undefined, comments: "" };
    await library().putTrack(blank);
    localStorage.setItem("trackUserChanges", "false");
    await player().playTracks("library", [blank], 0);
    const view = app(blank);
    fireEvent.click(view.getByRole("button", { name: "Selected track menu" }));
    expect(view.queryByRole("menuitem", { name: "Edit" })).toBeNull();
    fireEvent.click(view.getByRole("menuitem", { name: field }));
    const reader = await view.findByRole("dialog", { name: field });
    expect(within(reader).getByText(`No ${field.toLowerCase()}.`)).toBeTruthy();
    expect(within(reader).queryByRole("button", { name: "Edit" })).toBeNull();
    fireEvent.click(within(reader).getByRole("button", { name: "Close" }));
    await waitFor(() => expect(view.queryByRole("dialog")).toBeNull());
    fireEvent.click(view.getByRole("button", { name: "Lyrics" }));
    const playingReader = await view.findByRole("dialog", { name: "Lyrics" });
    expect(within(playingReader).getByText("No lyrics.")).toBeTruthy();
    expect(
      within(playingReader).queryByRole("button", { name: "Edit" })
    ).toBeNull();
  }
);

test.each(["Lyrics", "Comments"])(
  "read-only users can read nonempty %s without an edit entry",
  async (field) => {
    localStorage.setItem("trackUserChanges", "false");
    await player().playTracks("library", [first], 0);
    const view = app();
    fireEvent.click(view.getByRole("button", { name: "Selected track menu" }));
    fireEvent.click(view.getByRole("menuitem", { name: field }));
    const reader = await view.findByRole("dialog", { name: field });
    expect(
      within(reader).getByRole("region", { name: `${field} text` }).textContent
    ).toBe(field === "Lyrics" ? first.lyrics : first.comments);
    expect(within(reader).queryByRole("button", { name: "Edit" })).toBeNull();
  }
);

test("Now Playing disables Lyrics until there is a current track", () => {
  const view = app();
  expect(
    (view.getByRole("button", { name: "Lyrics" }) as HTMLButtonElement).disabled
  ).toBe(true);
});
