import "fake-indexeddb/auto";
import { afterEach, beforeEach, expect, test, vi } from "vitest";
import {
  act,
  cleanup,
  fireEvent,
  render,
  waitFor,
} from "@testing-library/react";
import axios, { AxiosError } from "axios";
import { Provider } from "jotai";
import { MemoryRouter } from "react-router-dom";
import library, { Track } from "../src/Library";
import { SyncManager } from "../src/SyncManager";
import EditTrackForm from "../src/EditTrackForm";
import TrackContextMenu from "../src/TrackContextMenu";
import { rateTrack, submitTrackEdit } from "../src/TrackEdit";
import { formFromTrack } from "../src/TrackEditForm";
import { UpdatePersister, updatePersister } from "../src/UpdatePersister";
import { player } from "../src/Player";
import { playingTrackAtom, store, updatedTrackAtom } from "../src/State";
import {
  Library,
  LibraryResponse,
  OperationResponse,
  SortName,
  Name,
  Track as WireTrack,
  TrackUpdate,
} from "../src/generated/messages";
import { SYNC_SUCCEEDED_TYPE } from "../src/WorkerTypes";
import { useTracks } from "../src/useTracks";

vi.mock("axios", async (importOriginal) => ({
  ...(await importOriginal<typeof import("axios")>()),
  default: { get: vi.fn(), post: vi.fn() },
}));
vi.mock("../src/DownloadWorker", () => ({
  DownloadWorker: { addEventListener: vi.fn(), postMessage: vi.fn() },
}));
vi.mock("../src/Files", () => ({
  files: () => ({ tryGetFileURL: async () => null }),
}));

const lyrics = "  first line\n\n第二行 🎶\n";
const comments = 'notes\n"quoted" \\ café';

async function readyLibrary() {
  await new Promise<void>((resolve) =>
    library().setInitializedListener(resolve)
  );
}

async function reloadLibrary() {
  library.cache.clear!();
  await readyLibrary();
}

async function syncText() {
  vi.mocked(axios.get).mockResolvedValueOnce({
    data: new LibraryResponse({
      library: new Library({
        updateTimeNs: 200,
        trackUserChanges: true,
        artists: new Map([[1, new SortName({ name: "artist" })]]),
        genres: new Map([[1, new Name({ name: "genre" })]]),
        tracks: [
          new WireTrack({
            id: "song",
            name: "song",
            artistId: 1,
            genreId: 1,
            duration: 200,
            finish: 200,
            musicFilename: "song.mp3",
            lyrics,
            comments,
          }),
          new WireTrack({ id: "blank", name: "blank" }),
        ],
      }),
    }).serialize(),
  });
  await new SyncManager().startSync("token", 0, true);
  expect(postMessage).toHaveBeenCalledWith({ type: SYNC_SUCCEEDED_TYPE });
  return (await library().getTrack("song"))!;
}

beforeEach(async () => {
  vi.clearAllMocks();
  vi.mocked(axios.get).mockReset();
  vi.mocked(axios.post).mockReset();
  vi.stubGlobal("postMessage", vi.fn());
  localStorage.clear();
  updatePersister.cache.clear!();
  await player().reset();
  await readyLibrary();
  library().clear();
  await library().getAllTracks();
  await library().getAllPlaylists();
  await library().putMetadata({
    type: "libraryMetadata",
    trackUserChanges: true,
    totalFileSize: 0,
    updateTimeNs: 200,
  });
});

afterEach(async () => {
  cleanup();
  await updatePersister().setAuthToken(null);
  vi.unstubAllGlobals();
});

test("sync saves every track's text for an offline library reload", async () => {
  const synced = await syncText();
  await reloadLibrary();
  vi.mocked(axios.get).mockRejectedValue(
    new AxiosError("offline", "ERR_NETWORK")
  );
  await new SyncManager().startSync("token", 200, false);

  expect(await library().getTrack("song")).toEqual(synced);
  expect(await library().getAllTracks()).toEqual(
    expect.arrayContaining([
      expect.objectContaining({ id: "song", lyrics, comments }),
      expect.objectContaining({ id: "blank", lyrics: "", comments: "" }),
    ])
  );
  expect(axios.get).toHaveBeenLastCalledWith("/api/version", expect.anything());
});

function DisplayTracks() {
  return useTracks().map((track) => (
    <output key={track.id} data-testid={track.id}>
      {JSON.stringify(track)}
    </output>
  ));
}

test.each([
  { lyrics: "new lyrics\n\n第二行 🎶\n" },
  { comments: 'new comments\n"quoted" \\ café' },
  { lyrics: "" },
  { comments: "" },
  { lyrics: "", comments: "" },
])(
  "form saves %j offline and delivers only those fields after reload",
  async (edits) => {
    const track = await syncText();
    vi.mocked(axios.post).mockRejectedValue(
      new AxiosError("offline", "ERR_NETWORK")
    );
    await updatePersister().setHasLibraryMetadata(true);
    await updatePersister().setAuthToken("token");
    await player().playTracks("library", [track], 0);
    const onClose = vi.fn();
    const view = render(
      <Provider store={store}>
        <DisplayTracks />
        <EditTrackForm track={track} onClose={onClose} />
      </Provider>
    );
    await waitFor(() =>
      expect(view.getByTestId("song").textContent).toContain(
        lyrics.replaceAll("\n", "\\n")
      )
    );
    expect(
      (view.getByRole("textbox", { name: "Lyrics" }) as HTMLTextAreaElement)
        .value
    ).toBe(lyrics);
    expect(
      (view.getByRole("textbox", { name: "Comments" }) as HTMLTextAreaElement)
        .value
    ).toBe(comments);
    for (const [field, value] of Object.entries(edits)) {
      const input = view.getByRole("textbox", {
        name: field === "lyrics" ? "Lyrics" : "Comments",
      });
      expect(input.tagName).toBe("TEXTAREA");
      fireEvent.change(input, { target: { value } });
    }
    fireEvent.click(view.getByRole("button", { name: "save" }));
    await waitFor(() => expect(onClose).toHaveBeenCalledOnce());

    const expected = { ...track, ...edits };
    expect(await library().getTrack(track.id)).toEqual(expected);
    expect(player().playingTrack?.track).toEqual(expected);
    expect(store.get(playingTrackAtom)?.track).toEqual(expected);
    expect(store.get(updatedTrackAtom)).toEqual(expected);
    expect(JSON.parse(view.getByTestId("song").textContent!)).toEqual(expected);
    expect(axios.post).toHaveBeenCalledOnce();

    cleanup();
    await updatePersister().setAuthToken(null);
    await reloadLibrary();
    expect(await library().getTrack(track.id)).toEqual(expected);
    const reloaded = new UpdatePersister();
    vi.mocked(axios.post).mockClear();
    vi.mocked(axios.post).mockResolvedValue({
      data: new OperationResponse({ success: true }).serialize(),
    });
    await reloaded.setHasLibraryMetadata(true);
    await reloaded.setAuthToken("token");
    expect(axios.post).toHaveBeenCalledOnce();
    const [path, payload, options] = vi.mocked(axios.post).mock.calls[0];
    expect(path).toBe(`/api/track/${track.id}`);
    expect(options?.headers).toEqual({
      Authorization: "Bearer token",
      "Content-Type": "application/octet-stream",
    });
    expect(payload).toEqual(new TrackUpdate(edits).serialize());
    expect(reloaded.pendingUpdates).toEqual([]);
    expect(localStorage.getItem("updates")).toBe("[]");
  }
);

test.each(["save", "cancel"])(
  "an unchanged %s leaves the track and queue alone",
  async (action) => {
    const track = await syncText();
    const onClose = vi.fn();
    const view = render(<EditTrackForm track={track} onClose={onClose} />);
    fireEvent.click(view.getByRole("button", { name: action }));
    await waitFor(() => expect(onClose).toHaveBeenCalledOnce());
    expect(await library().getTrack(track.id)).toEqual(track);
    expect(localStorage.getItem("updates")).toBeNull();
    expect(store.get(updatedTrackAtom)).toBeNull();
  }
);

test("cancel discards multiline edits without updating local or queued text", async () => {
  const track = await syncText();
  const onClose = vi.fn();
  const view = render(<EditTrackForm track={track} onClose={onClose} />);
  fireEvent.change(view.getByRole("textbox", { name: "Lyrics" }), {
    target: { value: "changed\nlyrics" },
  });
  fireEvent.change(view.getByRole("textbox", { name: "Comments" }), {
    target: { value: "" },
  });
  fireEvent.click(view.getByRole("button", { name: "cancel" }));
  expect(onClose).toHaveBeenCalledOnce();
  expect(await library().getTrack(track.id)).toEqual(track);
  expect(localStorage.getItem("updates")).toBeNull();
  expect(store.get(updatedTrackAtom)).toBeNull();
});

test("old cached tracks remain editable and unrelated rating edits preserve synced text", async () => {
  const track = await syncText();
  const legacy: Track = { ...track };
  delete legacy.lyrics;
  delete legacy.comments;
  await library().putTrack({ ...legacy, id: "legacy" });
  await reloadLibrary();
  const oldTrack = (await library().getTrack("legacy"))!;
  const onClose = vi.fn();
  const view = render(<EditTrackForm track={oldTrack} onClose={onClose} />);
  expect(
    (view.getByRole("textbox", { name: "Lyrics" }) as HTMLTextAreaElement).value
  ).toBe("");
  expect(
    (view.getByRole("textbox", { name: "Comments" }) as HTMLTextAreaElement)
      .value
  ).toBe("");
  fireEvent.click(view.getByRole("button", { name: "save" }));
  await waitFor(() => expect(onClose).toHaveBeenCalledOnce());
  expect(localStorage.getItem("updates")).toBeNull();

  await player().playTracks("library", [track], 0);
  await act(() => rateTrack(track, 80));
  expect(await library().getTrack(track.id)).toEqual({ ...track, rating: 80 });
  expect(player().playingTrack?.track).toEqual({ ...track, rating: 80 });
  const update = updatePersister().pendingUpdates[0];
  expect(update.type).toBe("track");
  if (update.type === "track") {
    expect(update.params.serialize()).toEqual(
      new TrackUpdate({ rating: 80 }).serialize()
    );
  }
});

test("a refresh replaces local text while leaving pending delivery unchanged", async () => {
  const track = await syncText();
  await submitTrackEdit(
    { ...formFromTrack(track), lyrics: "pending lyrics", comments: "" },
    track
  );
  expect(await library().getTrack(track.id)).toEqual({
    ...track,
    lyrics: "pending lyrics",
    comments: "",
  });
  const pending = localStorage.getItem("updates");
  expect(pending).not.toBeNull();

  await syncText();
  expect(await library().getTrack(track.id)).toEqual(track);
  expect(localStorage.getItem("updates")).toBe(pending);
});

test.each([true, false])(
  "the edit entry respects track changes policy %s",
  async (canEdit) => {
    const track = await syncText();
    localStorage.setItem("trackUserChanges", String(canEdit));
    const view = render(
      <MemoryRouter>
        <TrackContextMenu
          position={{ x: 0, y: 0 }}
          track={track}
          playlists={[]}
          onEdit={vi.fn()}
          onClose={vi.fn()}
        />
      </MemoryRouter>
    );
    expect(view.queryByRole("menuitem", { name: "Edit" }) !== null).toBe(
      canEdit
    );
  }
);
