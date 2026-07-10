import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import axios from "axios";
import library from "../src/Library";
import { files } from "../src/Files";
import { UpdatePersister, Update } from "../src/UpdatePersister";
import { OperationResponse, TrackUpdate } from "../src/generated/messages";
import {
  FileRequestSource,
  FileType,
  SET_SOURCE_REQUESTED_FILES_TYPE,
} from "../src/WorkerTypes";
import { DownloadWorker } from "../src/DownloadWorker";

vi.mock("axios");

vi.mock("../src/Library", () => {
  const MockLibrary = vi.fn();
  MockLibrary.prototype.getTrackUserChanges = vi.fn();

  const mockLibrary = new MockLibrary();
  return {
    default: vi.fn(() => mockLibrary),
  };
});

vi.mock("../src/DownloadWorker", () => {
  return {
    DownloadWorker: {
      postMessage: vi.fn(),
    },
  };
});

vi.mock("../src/Files", () => {
  const MockFiles = vi.fn();
  MockFiles.prototype.tryReadFile = vi.fn();

  const mockFiles = new MockFiles();
  return {
    files: vi.fn(() => mockFiles),
  };
});

function expectPlayPostRequest(id: string) {
  expect(axios.post).toHaveBeenCalledWith(
    `/api/play/${id}`,
    "",
    expect.objectContaining({
      headers: expect.objectContaining({
        Authorization: "Bearer mock-token",
        "Content-Type": "application/x-www-form-urlencoded",
      }),
    })
  );
}

const IMAGE_BLOB = new Blob(["mock data"], { type: "image/jpeg" });

function encodeTrackUpdate(message: TrackUpdate): string {
  return btoa(String.fromCharCode(...message.serialize()));
}

// track update params are message instances, so serialize them before
// comparing pending updates for equality
function normalized(updates: Update[]) {
  return updates.map((update) =>
    update.type === "track"
      ? { ...update, params: Array.from(update.params.serialize()) }
      : update
  );
}

function expectPendingUpdates(persister: UpdatePersister, expected: Update[]) {
  expect(normalized(persister.pendingUpdates)).toEqual(normalized(expected));
}

function expectTrackUpdatePostRequest(id: string, message: TrackUpdate) {
  expect(axios.post).toHaveBeenCalledWith(
    `/api/track/${id}`,
    expect.any(Uint8Array),
    expect.objectContaining({
      headers: expect.objectContaining({
        Authorization: "Bearer mock-token",
        "Content-Type": "application/octet-stream",
      }),
    })
  );

  const call = vi
    .mocked(axios.post)
    .mock.calls.filter((c) => c[0] === `/api/track/${id}`)[0];
  expect(Array.from(call[1] as Uint8Array)).toEqual(
    Array.from(message.serialize())
  );
}

function expectArtworkPostRequest() {
  expect(axios.post).toHaveBeenCalledWith(
    `/api/artwork`,
    expect.any(FormData),
    expect.objectContaining({
      headers: expect.objectContaining({
        Authorization: "Bearer mock-token",
        "Content-Type": "multipart/form-data",
      }),
    })
  );

  const call = vi
    .mocked(axios.post)
    .mock.calls.filter((c) => c[0] === "/api/artwork")[0];
  const file = (call[1] as FormData).get("file") as File;
  expect(file.name).toBe("hello.jpg");
  expect(file.size).toBe(IMAGE_BLOB.size);
}

enum ArtworkDownloadMessage {
  WITHOUT_FILE,
  WITH_FILE,
  BOTH,
}
function expectArtworkDownloadMessage(type: ArtworkDownloadMessage) {
  if (
    type === ArtworkDownloadMessage.WITH_FILE ||
    type === ArtworkDownloadMessage.WITHOUT_FILE
  ) {
    expect(DownloadWorker.postMessage).toHaveBeenCalledTimes(1);
  } else {
    expect(DownloadWorker.postMessage).toHaveBeenCalledTimes(2);
  }

  if (
    type === ArtworkDownloadMessage.WITH_FILE ||
    type === ArtworkDownloadMessage.BOTH
  ) {
    expect(DownloadWorker.postMessage).toHaveBeenCalledWith({
      type: SET_SOURCE_REQUESTED_FILES_TYPE,
      source: FileRequestSource.UPDATE_PERSISTER,
      fileType: FileType.ARTWORK,
      ids: [{ fileId: "hello.jpg", trackId: undefined }],
    });
  }
  if (
    type === ArtworkDownloadMessage.WITHOUT_FILE ||
    type === ArtworkDownloadMessage.BOTH
  ) {
    expect(DownloadWorker.postMessage).toHaveBeenCalledWith({
      type: SET_SOURCE_REQUESTED_FILES_TYPE,
      source: FileRequestSource.UPDATE_PERSISTER,
      fileType: FileType.ARTWORK,
      ids: [],
    });
  }
  vi.mocked(DownloadWorker.postMessage).mockClear();
}

function clearPostMock() {
  vi.mocked(axios.post).mockClear();
}

async function waitForUpdatesToFinish(persister: UpdatePersister) {
  await vi.waitFor(() => {
    if (persister.attemptingBulkUpdates) {
      throw new Error("still attempting");
    }
  });
}

describe("UpdatePersister", () => {
  const LOCAL_STORAGE_KEY = "updates";

  const OPERATION_SUCCEEDED = {
    data: new OperationResponse({
      success: true,
    }).serialize(),
  };
  const OPERATION_FAILED = {
    data: new OperationResponse({
      success: false,
      error: "error",
    }).serialize(),
  };

  const PLAY_UPDATE: Update = {
    type: "play",
    trackId: "123",
    params: undefined,
  };
  const PLAY_UPDATE_ARR_STR = JSON.stringify([PLAY_UPDATE]);

  const TRACK_UPDATE_MESSAGE = new TrackUpdate();
  TRACK_UPDATE_MESSAGE.artist = "hello";
  TRACK_UPDATE_MESSAGE.album = "goodbye";
  const TRACK_UPDATE: Update = {
    type: "track",
    trackId: "123",
    params: TRACK_UPDATE_MESSAGE,
  };
  const TRACK_UPDATE_ARR_STR = JSON.stringify([
    {
      type: "track",
      trackId: "123",
      params: encodeTrackUpdate(TRACK_UPDATE_MESSAGE),
    },
  ]);

  const ARTWORK_PARAMS = { filename: "hello.jpg" };
  const ARTWORK_UPDATE: Update = {
    type: "artwork",
    trackId: undefined,
    params: ARTWORK_PARAMS,
  };
  const ARTWORK_UPDATE_ARR_STR = JSON.stringify([ARTWORK_UPDATE]);

  beforeEach(() => {
    localStorage.clear();
    vi.useFakeTimers();
    vi.clearAllMocks();
    vi.clearAllTimers();
    // clearAllMocks does not drain queued mock*ValueOnce values (vitest 4),
    // so reset axios.post to avoid leaking unconsumed responses across tests
    vi.mocked(axios.post).mockReset();

    vi.mocked(files().tryReadFile).mockImplementation(
      (type: FileType, id: string) => {
        if (type === FileType.ARTWORK && id === "hello.jpg") {
          return Promise.resolve(IMAGE_BLOB as File);
        } else {
          return Promise.resolve(null);
        }
      }
    );
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.clearAllTimers();
  });

  it("should initialize with no pending updates if local storage key doesn't exist", () => {
    const persister = new UpdatePersister();
    expect(persister.pendingUpdates).toEqual([]);
    expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBeNull();
  });

  it("should do nothing on auth token set & library metadata set if there's nothing pending", async () => {
    const persister = new UpdatePersister();
    await persister.setAuthToken("mock-token");
    await persister.setHasLibraryMetadata(true);
    expect(axios.post).not.toHaveBeenCalled();
  });

  it("should drop any pending updates if track user changes is false", async () => {
    localStorage.setItem(LOCAL_STORAGE_KEY, PLAY_UPDATE_ARR_STR);
    const persister = new UpdatePersister();
    expect(persister.pendingUpdates).toEqual([PLAY_UPDATE]);

    vi.mocked(library().getTrackUserChanges).mockReturnValue(false);
    await persister.setAuthToken("mock-token");
    await persister.setHasLibraryMetadata(true);

    expect(persister.pendingUpdates).toEqual([]);
    expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe("[]");
  });

  describe("plays", () => {
    it("should initialize with pending play updates from local storage if they exist", () => {
      localStorage.setItem(LOCAL_STORAGE_KEY, PLAY_UPDATE_ARR_STR);
      const persister = new UpdatePersister();
      expect(persister.pendingUpdates).toEqual([PLAY_UPDATE]);
    });

    it("should attempt any pending updates when the auth token & library metadata is set", async () => {
      localStorage.setItem(LOCAL_STORAGE_KEY, PLAY_UPDATE_ARR_STR);
      vi.mocked(library().getTrackUserChanges).mockReturnValue(true);
      vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);

      const persister = new UpdatePersister();
      await persister.setAuthToken("mock-token");
      await persister.setHasLibraryMetadata(true);
      expectPlayPostRequest("123");
    });

    it("should add a play update to pending updates & persist if not authenticated", async () => {
      const persister = new UpdatePersister();
      vi.mocked(library().getTrackUserChanges).mockReturnValue(true);
      await persister.setHasLibraryMetadata(true);
      await persister.addPlay("123");

      expect(persister.pendingUpdates).toEqual([PLAY_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(PLAY_UPDATE_ARR_STR);
    });

    it("should add a play update to pending updates & persist if no library metadata", async () => {
      const persister = new UpdatePersister();
      await persister.setAuthToken("hi");
      await persister.addPlay("123");

      expect(persister.pendingUpdates).toEqual([PLAY_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(PLAY_UPDATE_ARR_STR);
    });

    it("should add a play update and immediately attempt it if authenticated", async () => {
      const persister = new UpdatePersister();
      await persister.setAuthToken("mock-token");
      vi.mocked(library().getTrackUserChanges).mockReturnValue(true);
      await persister.setHasLibraryMetadata(true);
      vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);

      await persister.addPlay("123");
      expectPlayPostRequest("123");
      expect(persister.pendingUpdates).toEqual([]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(null);
    });

    it("should do nothing if track user changes is false", async () => {
      const persister = new UpdatePersister();
      await persister.setAuthToken("mock-token");
      vi.mocked(library().getTrackUserChanges).mockReturnValue(false);
      await persister.setHasLibraryMetadata(true);
      vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);

      await persister.addPlay("123");
      expect(axios.post).toHaveBeenCalledTimes(0);
      expect(persister.pendingUpdates).toEqual([]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(null);
    });

    it("should retry sending pending updates on a timer", async () => {
      const persister = new UpdatePersister();
      await persister.setAuthToken("mock-token");
      vi.mocked(library().getTrackUserChanges).mockReturnValue(true);
      await persister.setHasLibraryMetadata(true);

      // fails on first attempt
      vi.mocked(axios.post).mockRejectedValueOnce(new Error("Network error"));
      await persister.addPlay("123");
      expect(persister.pendingUpdates).toEqual([PLAY_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(PLAY_UPDATE_ARR_STR);
      expectPlayPostRequest("123");
      clearPostMock();

      // fails on second attempt
      vi.mocked(axios.post).mockRejectedValueOnce(OPERATION_FAILED);
      vi.runOnlyPendingTimers();
      await waitForUpdatesToFinish(persister);
      expect(persister.pendingUpdates).toEqual([PLAY_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(PLAY_UPDATE_ARR_STR);
      expectPlayPostRequest("123");
      clearPostMock();

      // succeeds on third attempt
      vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);
      vi.runOnlyPendingTimers();
      await waitForUpdatesToFinish(persister);

      expectPlayPostRequest("123");
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe("[]");
      expect(persister.pendingUpdates).toEqual([]);
    });
  });

  it("should drop updates it doesn't recognize", () => {
    localStorage.setItem(
      LOCAL_STORAGE_KEY,
      JSON.stringify([
        { type: "nonsense", trackId: "123", params: {} },
        { type: "track", trackId: "123", params: "!!!not base64!!!" },
        { type: "rating", trackId: "123", params: {} },
      ])
    );
    const persister = new UpdatePersister();
    expect(persister.pendingUpdates).toEqual([]);
  });

  describe("track", () => {
    it("should initialize with pending track updates from local storage if they exist", () => {
      localStorage.setItem(LOCAL_STORAGE_KEY, TRACK_UPDATE_ARR_STR);
      const persister = new UpdatePersister();
      expectPendingUpdates(persister, [TRACK_UPDATE]);
    });

    it("should attempt any pending updates when the auth token & library metadata is set", async () => {
      localStorage.setItem(LOCAL_STORAGE_KEY, TRACK_UPDATE_ARR_STR);
      vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);
      vi.mocked(library().getTrackUserChanges).mockReturnValue(true);

      const persister = new UpdatePersister();
      await persister.setAuthToken("mock-token");
      await persister.setHasLibraryMetadata(true);
      expectTrackUpdatePostRequest("123", TRACK_UPDATE_MESSAGE);
    });

    it("should add a track update to pending updates & persist if not authenticated", async () => {
      const persister = new UpdatePersister();
      await persister.setHasLibraryMetadata(true);
      vi.mocked(library().getTrackUserChanges).mockReturnValue(true);
      await persister.updateTrack("123", TRACK_UPDATE_MESSAGE);

      expectPendingUpdates(persister, [TRACK_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
        TRACK_UPDATE_ARR_STR
      );
    });

    it("should add a track update to pending updates & persist if no library metadata", async () => {
      const persister = new UpdatePersister();
      await persister.setAuthToken("hi");
      await persister.updateTrack("123", TRACK_UPDATE_MESSAGE);

      expectPendingUpdates(persister, [TRACK_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
        TRACK_UPDATE_ARR_STR
      );
    });

    it("should add a track update and immediately attempt it if authenticated", async () => {
      const persister = new UpdatePersister();
      await persister.setAuthToken("mock-token");
      await persister.setHasLibraryMetadata(true);
      vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);
      vi.mocked(library().getTrackUserChanges).mockReturnValue(true);

      await persister.updateTrack("123", TRACK_UPDATE_MESSAGE);
      expectTrackUpdatePostRequest("123", TRACK_UPDATE_MESSAGE);
      expect(persister.pendingUpdates).toEqual([]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(null);
    });

    it("should do nothing if track user changes is false", async () => {
      const persister = new UpdatePersister();
      await persister.setAuthToken("mock-token");
      vi.mocked(library().getTrackUserChanges).mockReturnValue(false);
      await persister.setHasLibraryMetadata(true);
      vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);

      await persister.updateTrack("123", TRACK_UPDATE_MESSAGE);
      expect(axios.post).toHaveBeenCalledTimes(0);
      expect(persister.pendingUpdates).toEqual([]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(null);
    });

    it("should keep field presence through a persistence round trip", async () => {
      const message = new TrackUpdate();
      message.name = "new name";
      message.year = 1970;
      message.rating = 60;
      message.albumArtist = "";
      message.artwork = "";

      const persister = new UpdatePersister();
      await persister.updateTrack("123", message);

      const reloaded = new UpdatePersister();
      expect(reloaded.pendingUpdates.length).toBe(1);
      const update = reloaded.pendingUpdates[0];
      if (update.type !== "track") {
        throw new Error("expected a track update");
      }
      expect(update.params.name).toBe("new name");
      expect(update.params.year).toBe(1970);
      expect(update.params.rating).toBe(60);
      expect(update.params.has_albumArtist).toBe(true);
      expect(update.params.albumArtist).toBe("");
      expect(update.params.has_artwork).toBe(true);
      expect(update.params.artwork).toBe("");
      expect(update.params.has_album).toBe(false);
      expect(update.params.has_artist).toBe(false);
      expect(update.params.has_genre).toBe(false);
      expect(update.params.has_start).toBe(false);
      expect(update.params.has_finish).toBe(false);
    });

    it("should retry sending pending updates on a timer", async () => {
      const persister = new UpdatePersister();
      await persister.setAuthToken("mock-token");
      await persister.setHasLibraryMetadata(true);
      vi.mocked(library().getTrackUserChanges).mockReturnValue(true);

      // fails on first attempt
      vi.mocked(axios.post).mockRejectedValueOnce(new Error("Network error"));
      await persister.updateTrack("123", TRACK_UPDATE_MESSAGE);
      expectPendingUpdates(persister, [TRACK_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
        TRACK_UPDATE_ARR_STR
      );
      expectTrackUpdatePostRequest("123", TRACK_UPDATE_MESSAGE);
      clearPostMock();

      // fails on second attempt
      vi.mocked(axios.post).mockRejectedValueOnce(OPERATION_FAILED);
      vi.runOnlyPendingTimers();
      await waitForUpdatesToFinish(persister);
      expectPendingUpdates(persister, [TRACK_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
        TRACK_UPDATE_ARR_STR
      );
      expectTrackUpdatePostRequest("123", TRACK_UPDATE_MESSAGE);
      clearPostMock();

      // succeeds on third attempt
      vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);
      vi.runOnlyPendingTimers();
      await waitForUpdatesToFinish(persister);

      expectTrackUpdatePostRequest("123", TRACK_UPDATE_MESSAGE);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe("[]");
      expect(persister.pendingUpdates).toEqual([]);
    });
  });

  describe("artwork", () => {
    it("should initialize with pending artwork updates from local storage if they exist", () => {
      localStorage.setItem(LOCAL_STORAGE_KEY, ARTWORK_UPDATE_ARR_STR);
      const persister = new UpdatePersister();
      expect(persister.pendingUpdates).toEqual([ARTWORK_UPDATE]);
      expectArtworkDownloadMessage(ArtworkDownloadMessage.WITH_FILE);
    });

    it("should attempt any pending updates when the auth token & library metadata is set", async () => {
      localStorage.setItem(LOCAL_STORAGE_KEY, ARTWORK_UPDATE_ARR_STR);
      vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);
      vi.mocked(library().getTrackUserChanges).mockReturnValue(true);

      const persister = new UpdatePersister();
      expectArtworkDownloadMessage(ArtworkDownloadMessage.WITH_FILE);
      await persister.setAuthToken("mock-token");
      await persister.setHasLibraryMetadata(true);
      expectArtworkPostRequest();
      expectArtworkDownloadMessage(ArtworkDownloadMessage.WITHOUT_FILE);
    });

    it("should add an artwork update to pending updates & persist if not authenticated", async () => {
      const persister = new UpdatePersister();
      expectArtworkDownloadMessage(ArtworkDownloadMessage.WITHOUT_FILE);
      persister.setHasLibraryMetadata(true);
      vi.mocked(library().getTrackUserChanges).mockReturnValue(true);
      await persister.uploadArtwork("hello.jpg");

      expect(persister.pendingUpdates).toEqual([ARTWORK_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
        ARTWORK_UPDATE_ARR_STR
      );
      expectArtworkDownloadMessage(ArtworkDownloadMessage.WITH_FILE);
    });

    it("should add a artwork update to pending updates & persist if no library metadata", async () => {
      const persister = new UpdatePersister();
      expectArtworkDownloadMessage(ArtworkDownloadMessage.WITHOUT_FILE);
      persister.setAuthToken("hi");
      await persister.uploadArtwork("hello.jpg");

      expect(persister.pendingUpdates).toEqual([ARTWORK_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
        ARTWORK_UPDATE_ARR_STR
      );
      expectArtworkDownloadMessage(ArtworkDownloadMessage.WITH_FILE);
    });

    it("should add a artwork update and immediately attempt it if authenticated", async () => {
      const persister = new UpdatePersister();
      expectArtworkDownloadMessage(ArtworkDownloadMessage.WITHOUT_FILE);
      persister.setAuthToken("mock-token");
      persister.setHasLibraryMetadata(true);
      vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);
      vi.mocked(library().getTrackUserChanges).mockReturnValue(true);

      await persister.uploadArtwork("hello.jpg");
      expectArtworkDownloadMessage(ArtworkDownloadMessage.BOTH);
      expectArtworkPostRequest();
      expect(persister.pendingUpdates).toEqual([]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(null);
    });

    it("should do nothing if track user changes is false", async () => {
      const persister = new UpdatePersister();
      expectArtworkDownloadMessage(ArtworkDownloadMessage.WITHOUT_FILE);
      persister.setAuthToken("mock-token");
      vi.mocked(library().getTrackUserChanges).mockReturnValue(false);
      persister.setHasLibraryMetadata(true);
      vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);

      await persister.uploadArtwork("hello.jpg");
      expect(axios.post).toHaveBeenCalledTimes(0);
      expect(persister.pendingUpdates).toEqual([]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(null);
    });

    it("should retry sending pending updates on a timer", async () => {
      const persister = new UpdatePersister();
      expectArtworkDownloadMessage(ArtworkDownloadMessage.WITHOUT_FILE);
      persister.setAuthToken("mock-token");
      persister.setHasLibraryMetadata(true);
      vi.mocked(library().getTrackUserChanges).mockReturnValue(true);

      // fails on first attempt
      vi.mocked(axios.post).mockRejectedValueOnce(new Error("Network error"));
      await persister.uploadArtwork("hello.jpg");
      expectArtworkDownloadMessage(ArtworkDownloadMessage.WITH_FILE);
      expect(persister.pendingUpdates).toEqual([ARTWORK_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
        ARTWORK_UPDATE_ARR_STR
      );
      expectArtworkPostRequest();
      clearPostMock();

      // fails on second attempt
      vi.mocked(axios.post).mockRejectedValueOnce(OPERATION_FAILED);
      vi.runOnlyPendingTimers();
      await waitForUpdatesToFinish(persister);
      expect(persister.pendingUpdates).toEqual([ARTWORK_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
        ARTWORK_UPDATE_ARR_STR
      );
      expectArtworkPostRequest();
      clearPostMock();

      // succeeds on third attempt
      vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);
      vi.runOnlyPendingTimers();
      await waitForUpdatesToFinish(persister);

      expectArtworkPostRequest();
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe("[]");
      expect(persister.pendingUpdates).toEqual([]);
      expectArtworkDownloadMessage(ArtworkDownloadMessage.WITHOUT_FILE);
    });
  });

  it("should support intermittent failing requests and adding while attempting updates", async () => {
    const ratingMessage = new TrackUpdate({ rating: 60 });
    const persisted: object[] = [
      { type: "play", trackId: "123", params: undefined },
      {
        type: "track",
        trackId: "456",
        params: encodeTrackUpdate(ratingMessage),
      },
      {
        type: "track",
        trackId: "789",
        params: encodeTrackUpdate(TRACK_UPDATE_MESSAGE),
      },
      { type: "artwork", trackId: undefined, params: ARTWORK_PARAMS },
    ];
    const updates: Update[] = [
      { type: "play", trackId: "123", params: undefined },
      { type: "track", trackId: "456", params: ratingMessage },
      { type: "track", trackId: "789", params: TRACK_UPDATE_MESSAGE },
      { type: "artwork", trackId: undefined, params: ARTWORK_PARAMS },
    ];
    localStorage.setItem(LOCAL_STORAGE_KEY, JSON.stringify(persisted));
    persisted.push({ type: "play", trackId: "abc", params: undefined });
    updates.push({ type: "play", trackId: "abc", params: undefined });
    const persister = new UpdatePersister();
    expectArtworkDownloadMessage(ArtworkDownloadMessage.WITH_FILE);
    vi.mocked(library().getTrackUserChanges).mockReturnValue(true);

    // first attempt: only 456 succeeds
    vi.mocked(axios.post).mockRejectedValueOnce(new Error("Network error"));
    vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);
    vi.mocked(axios.post).mockRejectedValueOnce(new Error("Network error"));
    vi.mocked(axios.post).mockRejectedValueOnce(new Error("Network error"));
    vi.mocked(axios.post).mockRejectedValueOnce(new Error("Network error"));
    persister.setAuthToken("mock-token");
    persister.setHasLibraryMetadata(true);
    persister.addPlay("abc"); // add another one, why not
    await waitForUpdatesToFinish(persister);
    expectPlayPostRequest("123");
    expectTrackUpdatePostRequest("456", ratingMessage);
    expectTrackUpdatePostRequest("789", TRACK_UPDATE_MESSAGE);
    expectArtworkPostRequest();
    expectPlayPostRequest("abc");
    clearPostMock();
    expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
      JSON.stringify([persisted[0], persisted[2], persisted[3], persisted[4]])
    );
    expectPendingUpdates(persister, [
      updates[0],
      updates[2],
      updates[3],
      updates[4],
    ]);

    // second attempt: only abc succeeds
    vi.mocked(axios.post).mockRejectedValueOnce(new Error("Network error"));
    vi.mocked(axios.post).mockRejectedValueOnce(OPERATION_FAILED);
    vi.mocked(axios.post).mockRejectedValueOnce(new Error("Network error"));
    vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);
    persister.setAuthToken("mock-token");
    await waitForUpdatesToFinish(persister);
    expectPlayPostRequest("123");
    expectTrackUpdatePostRequest("789", TRACK_UPDATE_MESSAGE);
    expectArtworkPostRequest();
    expectPlayPostRequest("abc");
    clearPostMock();
    expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
      JSON.stringify([persisted[0], persisted[2], persisted[3]])
    );
    expectPendingUpdates(persister, [updates[0], updates[2], updates[3]]);

    // third attempt: only 123 succeeds
    vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);
    vi.mocked(axios.post).mockRejectedValueOnce(new Error("Network error"));
    vi.mocked(axios.post).mockRejectedValueOnce(new Error("Network error"));
    persister.setAuthToken("mock-token");
    await waitForUpdatesToFinish(persister);
    expectPlayPostRequest("123");
    expectTrackUpdatePostRequest("789", TRACK_UPDATE_MESSAGE);
    expectArtworkPostRequest();
    clearPostMock();
    expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
      JSON.stringify([persisted[2], persisted[3]])
    );
    expectPendingUpdates(persister, [updates[2], updates[3]]);

    // fourth attempt: 789 succeeds
    vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);
    vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_FAILED);
    persister.setAuthToken("mock-token");
    await waitForUpdatesToFinish(persister);
    expectTrackUpdatePostRequest("789", TRACK_UPDATE_MESSAGE);
    expectArtworkPostRequest();
    clearPostMock();
    expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
      JSON.stringify([persisted[3]])
    );
    expectPendingUpdates(persister, [updates[3]]);

    // fourth attempt: artwork succeeds
    vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);
    persister.setAuthToken("mock-token");
    await waitForUpdatesToFinish(persister);
    expectArtworkPostRequest();
    clearPostMock();
    expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe("[]");
    expect(persister.pendingUpdates).toEqual([]);
    expectArtworkDownloadMessage(ArtworkDownloadMessage.WITHOUT_FILE);
  });
});
