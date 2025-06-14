import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import axios from "axios";
import qs from "qs";
import library from "../src/Library";
import { files } from "../src/Files";
import { UpdatePersister, Update } from "../src/UpdatePersister";
import { OperationResponse } from "../src/generated/messages";
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

function expectRatingPostRequest(id: string, value: number) {
  expect(axios.post).toHaveBeenCalledWith(
    `/api/rating/${id}`,
    `rating=${value}`,
    expect.objectContaining({
      headers: expect.objectContaining({
        Authorization: "Bearer mock-token",
        "Content-Type": "application/x-www-form-urlencoded",
      }),
    })
  );
}

function expectTrackInfoPostRequest(id: string, updates: object) {
  expect(axios.post).toHaveBeenCalledWith(
    `/api/track-info/${id}`,
    qs.stringify(updates),
    expect.objectContaining({
      headers: expect.objectContaining({
        Authorization: "Bearer mock-token",
        "Content-Type": "application/x-www-form-urlencoded",
      }),
    })
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
    .mock.calls.filter((c) => c[0] == "/api/artwork")[0];
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

  const RATING_UPDATE: Update = {
    type: "rating",
    trackId: "123",
    params: { rating: 60 },
  };
  const RATING_UPDATE_ARR_STR = JSON.stringify([RATING_UPDATE]);

  const TRACK_INFO_PARAMS = { artist: "hello", album: "goodbye" };
  const TRACK_INFO_UPDATE: Update = {
    type: "track-info",
    trackId: "123",
    params: TRACK_INFO_PARAMS,
  };
  const TRACK_INFO_UPDATE_ARR_STR = JSON.stringify([TRACK_INFO_UPDATE]);

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

    vi.mocked(files().tryReadFile).mockImplementation(
      (type: FileType, id: string) => {
        if (type === FileType.ARTWORK && id == "hello.jpg") {
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

  describe("ratings", () => {
    it("should initialize with pending rating updates from local storage if they exist", () => {
      localStorage.setItem(LOCAL_STORAGE_KEY, RATING_UPDATE_ARR_STR);
      const persister = new UpdatePersister();
      expect(persister.pendingUpdates).toEqual([RATING_UPDATE]);
    });

    it("should attempt any pending updates when the auth token & library metadata is set", async () => {
      localStorage.setItem(LOCAL_STORAGE_KEY, RATING_UPDATE_ARR_STR);
      vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);
      vi.mocked(library().getTrackUserChanges).mockReturnValue(true);

      const persister = new UpdatePersister();
      await persister.setAuthToken("mock-token");
      await persister.setHasLibraryMetadata(true);
      expectRatingPostRequest("123", 60);
    });

    it("should add a rating update to pending updates & persist if not authenticated", async () => {
      const persister = new UpdatePersister();
      await persister.setHasLibraryMetadata(true);
      vi.mocked(library().getTrackUserChanges).mockReturnValue(true);
      await persister.updateRating("123", 60);

      expect(persister.pendingUpdates).toEqual([RATING_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
        RATING_UPDATE_ARR_STR
      );
    });

    it("should add a rating update to pending updates & persist if no library metadata", async () => {
      const persister = new UpdatePersister();
      await persister.setAuthToken("hi");
      await persister.updateRating("123", 60);

      expect(persister.pendingUpdates).toEqual([RATING_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
        RATING_UPDATE_ARR_STR
      );
    });

    it("should add a rating update and immediately attempt it if authenticated", async () => {
      const persister = new UpdatePersister();
      await persister.setAuthToken("mock-token");
      await persister.setHasLibraryMetadata(true);
      vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);
      vi.mocked(library().getTrackUserChanges).mockReturnValue(true);

      await persister.updateRating("123", 60);
      expectRatingPostRequest("123", 60);
      expect(persister.pendingUpdates).toEqual([]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(null);
    });

    it("should do nothing if track user changes is false", async () => {
      const persister = new UpdatePersister();
      await persister.setAuthToken("mock-token");
      vi.mocked(library().getTrackUserChanges).mockReturnValue(false);
      await persister.setHasLibraryMetadata(true);
      vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);

      await persister.updateRating("123", 60);
      expect(axios.post).toHaveBeenCalledTimes(0);
      expect(persister.pendingUpdates).toEqual([]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(null);
    });

    it("should retry sending pending updates on a timer", async () => {
      const persister = new UpdatePersister();
      await persister.setAuthToken("mock-token");
      await persister.setHasLibraryMetadata(true);
      vi.mocked(library().getTrackUserChanges).mockReturnValue(true);

      // fails on first attempt
      vi.mocked(axios.post).mockRejectedValueOnce(new Error("Network error"));
      await persister.updateRating("123", 60);
      expect(persister.pendingUpdates).toEqual([RATING_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
        RATING_UPDATE_ARR_STR
      );
      expectRatingPostRequest("123", 60);
      clearPostMock();

      // fails on second attempt
      vi.mocked(axios.post).mockRejectedValueOnce(OPERATION_FAILED);
      vi.runOnlyPendingTimers();
      await waitForUpdatesToFinish(persister);
      expect(persister.pendingUpdates).toEqual([RATING_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
        RATING_UPDATE_ARR_STR
      );
      expectRatingPostRequest("123", 60);
      clearPostMock();

      // succeeds on third attempt
      vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);
      vi.runOnlyPendingTimers();
      await waitForUpdatesToFinish(persister);

      expectRatingPostRequest("123", 60);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe("[]");
      expect(persister.pendingUpdates).toEqual([]);
    });
  });

  describe("track-info", () => {
    it("should initialize with pending track info updates from local storage if they exist", () => {
      localStorage.setItem(LOCAL_STORAGE_KEY, TRACK_INFO_UPDATE_ARR_STR);
      const persister = new UpdatePersister();
      expect(persister.pendingUpdates).toEqual([TRACK_INFO_UPDATE]);
    });

    it("should attempt any pending updates when the auth token & library metadata is set", async () => {
      localStorage.setItem(LOCAL_STORAGE_KEY, TRACK_INFO_UPDATE_ARR_STR);
      vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);
      vi.mocked(library().getTrackUserChanges).mockReturnValue(true);

      const persister = new UpdatePersister();
      await persister.setAuthToken("mock-token");
      await persister.setHasLibraryMetadata(true);
      expectTrackInfoPostRequest("123", TRACK_INFO_UPDATE.params!);
    });

    it("should add a track info update to pending updates & persist if not authenticated", async () => {
      const persister = new UpdatePersister();
      await persister.setHasLibraryMetadata(true);
      vi.mocked(library().getTrackUserChanges).mockReturnValue(true);
      await persister.updateTrackInfo("123", TRACK_INFO_PARAMS);

      expect(persister.pendingUpdates).toEqual([TRACK_INFO_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
        TRACK_INFO_UPDATE_ARR_STR
      );
    });

    it("should add a track info update to pending updates & persist if no library metadata", async () => {
      const persister = new UpdatePersister();
      await persister.setAuthToken("hi");
      await persister.updateTrackInfo("123", TRACK_INFO_PARAMS);

      expect(persister.pendingUpdates).toEqual([TRACK_INFO_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
        TRACK_INFO_UPDATE_ARR_STR
      );
    });

    it("should add a track info update and immediately attempt it if authenticated", async () => {
      const persister = new UpdatePersister();
      await persister.setAuthToken("mock-token");
      await persister.setHasLibraryMetadata(true);
      vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);
      vi.mocked(library().getTrackUserChanges).mockReturnValue(true);

      await persister.updateTrackInfo("123", TRACK_INFO_PARAMS);
      expectTrackInfoPostRequest("123", TRACK_INFO_PARAMS);
      expect(persister.pendingUpdates).toEqual([]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(null);
    });

    it("should do nothing if track user changes is false", async () => {
      const persister = new UpdatePersister();
      await persister.setAuthToken("mock-token");
      vi.mocked(library().getTrackUserChanges).mockReturnValue(false);
      await persister.setHasLibraryMetadata(true);
      vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);

      await persister.updateTrackInfo("123", TRACK_INFO_PARAMS);
      expect(axios.post).toHaveBeenCalledTimes(0);
      expect(persister.pendingUpdates).toEqual([]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(null);
    });

    it("should retry sending pending updates on a timer", async () => {
      const persister = new UpdatePersister();
      await persister.setAuthToken("mock-token");
      await persister.setHasLibraryMetadata(true);
      vi.mocked(library().getTrackUserChanges).mockReturnValue(true);

      // fails on first attempt
      vi.mocked(axios.post).mockRejectedValueOnce(new Error("Network error"));
      await persister.updateTrackInfo("123", TRACK_INFO_PARAMS);
      expect(persister.pendingUpdates).toEqual([TRACK_INFO_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
        TRACK_INFO_UPDATE_ARR_STR
      );
      expectTrackInfoPostRequest("123", TRACK_INFO_PARAMS);
      clearPostMock();

      // fails on second attempt
      vi.mocked(axios.post).mockRejectedValueOnce(OPERATION_FAILED);
      vi.runOnlyPendingTimers();
      await waitForUpdatesToFinish(persister);
      expect(persister.pendingUpdates).toEqual([TRACK_INFO_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
        TRACK_INFO_UPDATE_ARR_STR
      );
      expectTrackInfoPostRequest("123", TRACK_INFO_PARAMS);
      clearPostMock();

      // succeeds on third attempt
      vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);
      vi.runOnlyPendingTimers();
      await waitForUpdatesToFinish(persister);

      expectTrackInfoPostRequest("123", TRACK_INFO_PARAMS);
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
    const updates: Update[] = [
      { type: "play", trackId: "123", params: undefined },
      { type: "rating", trackId: "456", params: { rating: 60 } },
      { type: "track-info", trackId: "789", params: TRACK_INFO_PARAMS },
      { type: "artwork", trackId: undefined, params: ARTWORK_PARAMS },
    ];
    localStorage.setItem(LOCAL_STORAGE_KEY, JSON.stringify(updates));
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
    expectRatingPostRequest("456", 60);
    expectTrackInfoPostRequest("789", TRACK_INFO_PARAMS);
    expectArtworkPostRequest();
    expectPlayPostRequest("abc");
    clearPostMock();
    expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
      JSON.stringify([updates[0], updates[2], updates[3], updates[4]])
    );
    expect(persister.pendingUpdates).toEqual([
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
    expectTrackInfoPostRequest("789", TRACK_INFO_PARAMS);
    expectArtworkPostRequest();
    expectPlayPostRequest("abc");
    clearPostMock();
    expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
      JSON.stringify([updates[0], updates[2], updates[3]])
    );
    expect(persister.pendingUpdates).toEqual([
      updates[0],
      updates[2],
      updates[3],
    ]);

    // third attempt: only 123 succeeds
    vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);
    vi.mocked(axios.post).mockRejectedValueOnce(new Error("Network error"));
    vi.mocked(axios.post).mockRejectedValueOnce(new Error("Network error"));
    persister.setAuthToken("mock-token");
    await waitForUpdatesToFinish(persister);
    expectPlayPostRequest("123");
    expectTrackInfoPostRequest("789", TRACK_INFO_PARAMS);
    expectArtworkPostRequest();
    clearPostMock();
    expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
      JSON.stringify([updates[2], updates[3]])
    );
    expect(persister.pendingUpdates).toEqual([updates[2], updates[3]]);

    // fourth attempt: 789 succeeds
    vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_SUCCEEDED);
    vi.mocked(axios.post).mockResolvedValueOnce(OPERATION_FAILED);
    persister.setAuthToken("mock-token");
    await waitForUpdatesToFinish(persister);
    expectTrackInfoPostRequest("789", TRACK_INFO_PARAMS);
    expectArtworkPostRequest();
    clearPostMock();
    expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
      JSON.stringify([updates[3]])
    );
    expect(persister.pendingUpdates).toEqual([updates[3]]);

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
