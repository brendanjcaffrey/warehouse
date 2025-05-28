import { describe, it, expect, vi, beforeEach, afterEach, Mock } from "vitest";
import axios from "axios";
import qs from "qs";
import library from "../src/Library";
import { UpdatePersister, Update } from "../src/UpdatePersister";
import { OperationResponse } from "../src/generated/messages";

vi.mock("axios");

vi.mock("../src/Library", () => {
  const MockLibrary = vi.fn();
  MockLibrary.prototype.getTrackUserChanges = vi.fn();

  const mockLibrary = new MockLibrary();
  return {
    default: vi.fn(() => mockLibrary),
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

function clearPostMock() {
  (axios.post as Mock).mockClear();
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

  beforeEach(() => {
    localStorage.clear();
    vi.useFakeTimers();
    vi.clearAllMocks();
    vi.clearAllTimers();
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

  it("should do nothing on auth token set & library metadata set if there's nothing pending", () => {
    const persister = new UpdatePersister();
    persister.setAuthToken("mock-token");
    persister.setHasLibraryMetadata(true);
    expect(axios.post).not.toHaveBeenCalled();
  });

  it("should drop any pending updates if track user changes is false", () => {
    localStorage.setItem(LOCAL_STORAGE_KEY, PLAY_UPDATE_ARR_STR);
    const persister = new UpdatePersister();
    expect(persister.pendingUpdates).toEqual([PLAY_UPDATE]);

    (library().getTrackUserChanges as Mock).mockReturnValue(false);
    persister.setAuthToken("mock-token");
    persister.setHasLibraryMetadata(true);

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
      (library().getTrackUserChanges as Mock).mockReturnValue(true);
      (axios.post as Mock).mockResolvedValueOnce(OPERATION_SUCCEEDED);

      const persister = new UpdatePersister();
      persister.setAuthToken("mock-token");
      persister.setHasLibraryMetadata(true);
      expectPlayPostRequest("123");
    });

    it("should add a play update to pending updates & persist if not authenticated", async () => {
      const persister = new UpdatePersister();
      (library().getTrackUserChanges as Mock).mockReturnValue(true);
      persister.setHasLibraryMetadata(true);
      await persister.addPlay("123");

      expect(persister.pendingUpdates).toEqual([PLAY_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(PLAY_UPDATE_ARR_STR);
    });

    it("should add a play update to pending updates & persist if no library metadata", async () => {
      const persister = new UpdatePersister();
      persister.setAuthToken("hi");
      await persister.addPlay("123");

      expect(persister.pendingUpdates).toEqual([PLAY_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(PLAY_UPDATE_ARR_STR);
    });

    it("should add a play update and immediately attempt it if authenticated", async () => {
      const persister = new UpdatePersister();
      persister.setAuthToken("mock-token");
      (library().getTrackUserChanges as Mock).mockReturnValue(true);
      persister.setHasLibraryMetadata(true);
      (axios.post as Mock).mockResolvedValueOnce(OPERATION_SUCCEEDED);

      await persister.addPlay("123");
      expectPlayPostRequest("123");
      expect(persister.pendingUpdates).toEqual([]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(null);
    });

    it("should do nothing if track user changes is false", async () => {
      const persister = new UpdatePersister();
      persister.setAuthToken("mock-token");
      (library().getTrackUserChanges as Mock).mockReturnValue(false);
      persister.setHasLibraryMetadata(true);
      (axios.post as Mock).mockResolvedValueOnce(OPERATION_SUCCEEDED);

      await persister.addPlay("123");
      expect(axios.post).toHaveBeenCalledTimes(0);
      expect(persister.pendingUpdates).toEqual([]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(null);
    });

    it("should retry sending pending updates on a timer", async () => {
      const persister = new UpdatePersister();
      persister.setAuthToken("mock-token");
      (library().getTrackUserChanges as Mock).mockReturnValue(true);
      persister.setHasLibraryMetadata(true);

      // fails on first attempt
      (axios.post as Mock).mockRejectedValueOnce(new Error("Network error"));
      await persister.addPlay("123");
      expect(persister.pendingUpdates).toEqual([PLAY_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(PLAY_UPDATE_ARR_STR);
      expectPlayPostRequest("123");
      clearPostMock();

      // fails on second attempt
      (axios.post as Mock).mockRejectedValueOnce(OPERATION_FAILED);
      vi.runOnlyPendingTimers();
      await waitForUpdatesToFinish(persister);
      expect(persister.pendingUpdates).toEqual([PLAY_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(PLAY_UPDATE_ARR_STR);
      expectPlayPostRequest("123");
      clearPostMock();

      // succeeds on third attempt
      (axios.post as Mock).mockResolvedValueOnce(OPERATION_SUCCEEDED);
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
      (axios.post as Mock).mockResolvedValueOnce(OPERATION_SUCCEEDED);
      (library().getTrackUserChanges as Mock).mockReturnValue(true);

      const persister = new UpdatePersister();
      persister.setAuthToken("mock-token");
      persister.setHasLibraryMetadata(true);
      expectRatingPostRequest("123", 60);
    });

    it("should add a rating update to pending updates & persist if not authenticated", async () => {
      const persister = new UpdatePersister();
      persister.setHasLibraryMetadata(true);
      (library().getTrackUserChanges as Mock).mockReturnValue(true);
      await persister.updateRating("123", 60);

      expect(persister.pendingUpdates).toEqual([RATING_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
        RATING_UPDATE_ARR_STR
      );
    });

    it("should add a rating update to pending updates & persist if no library metadata", async () => {
      const persister = new UpdatePersister();
      persister.setAuthToken("hi");
      await persister.updateRating("123", 60);

      expect(persister.pendingUpdates).toEqual([RATING_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
        RATING_UPDATE_ARR_STR
      );
    });

    it("should add a rating update and immediately attempt it if authenticated", async () => {
      const persister = new UpdatePersister();
      persister.setAuthToken("mock-token");
      persister.setHasLibraryMetadata(true);
      (axios.post as Mock).mockResolvedValueOnce(OPERATION_SUCCEEDED);
      (library().getTrackUserChanges as Mock).mockReturnValue(true);

      await persister.updateRating("123", 60);
      expectRatingPostRequest("123", 60);
      expect(persister.pendingUpdates).toEqual([]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(null);
    });

    it("should do nothing if track user changes is false", async () => {
      const persister = new UpdatePersister();
      persister.setAuthToken("mock-token");
      (library().getTrackUserChanges as Mock).mockReturnValue(false);
      persister.setHasLibraryMetadata(true);
      (axios.post as Mock).mockResolvedValueOnce(OPERATION_SUCCEEDED);

      await persister.updateRating("123", 60);
      expect(axios.post).toHaveBeenCalledTimes(0);
      expect(persister.pendingUpdates).toEqual([]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(null);
    });

    it("should retry sending pending updates on a timer", async () => {
      const persister = new UpdatePersister();
      persister.setAuthToken("mock-token");
      persister.setHasLibraryMetadata(true);
      (library().getTrackUserChanges as Mock).mockReturnValue(true);

      // fails on first attempt
      (axios.post as Mock).mockRejectedValueOnce(new Error("Network error"));
      await persister.updateRating("123", 60);
      expect(persister.pendingUpdates).toEqual([RATING_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
        RATING_UPDATE_ARR_STR
      );
      expectRatingPostRequest("123", 60);
      clearPostMock();

      // fails on second attempt
      (axios.post as Mock).mockRejectedValueOnce(OPERATION_FAILED);
      vi.runOnlyPendingTimers();
      await waitForUpdatesToFinish(persister);
      expect(persister.pendingUpdates).toEqual([RATING_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
        RATING_UPDATE_ARR_STR
      );
      expectRatingPostRequest("123", 60);
      clearPostMock();

      // succeeds on third attempt
      (axios.post as Mock).mockResolvedValueOnce(OPERATION_SUCCEEDED);
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
      (axios.post as Mock).mockResolvedValueOnce(OPERATION_SUCCEEDED);
      (library().getTrackUserChanges as Mock).mockReturnValue(true);

      const persister = new UpdatePersister();
      persister.setAuthToken("mock-token");
      persister.setHasLibraryMetadata(true);
      expectTrackInfoPostRequest("123", TRACK_INFO_UPDATE.params!);
    });

    it("should add a track info update to pending updates & persist if not authenticated", async () => {
      const persister = new UpdatePersister();
      persister.setHasLibraryMetadata(true);
      (library().getTrackUserChanges as Mock).mockReturnValue(true);
      await persister.updateTrackInfo("123", TRACK_INFO_PARAMS);

      expect(persister.pendingUpdates).toEqual([TRACK_INFO_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
        TRACK_INFO_UPDATE_ARR_STR
      );
    });

    it("should add a track info update to pending updates & persist if no library metadata", async () => {
      const persister = new UpdatePersister();
      persister.setAuthToken("hi");
      await persister.updateTrackInfo("123", TRACK_INFO_PARAMS);

      expect(persister.pendingUpdates).toEqual([TRACK_INFO_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
        TRACK_INFO_UPDATE_ARR_STR
      );
    });

    it("should add a track info update and immediately attempt it if authenticated", async () => {
      const persister = new UpdatePersister();
      persister.setAuthToken("mock-token");
      persister.setHasLibraryMetadata(true);
      (axios.post as Mock).mockResolvedValueOnce(OPERATION_SUCCEEDED);
      (library().getTrackUserChanges as Mock).mockReturnValue(true);

      await persister.updateTrackInfo("123", TRACK_INFO_PARAMS);
      expectTrackInfoPostRequest("123", TRACK_INFO_PARAMS);
      expect(persister.pendingUpdates).toEqual([]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(null);
    });

    it("should do nothing if track user changes is false", async () => {
      const persister = new UpdatePersister();
      persister.setAuthToken("mock-token");
      (library().getTrackUserChanges as Mock).mockReturnValue(false);
      persister.setHasLibraryMetadata(true);
      (axios.post as Mock).mockResolvedValueOnce(OPERATION_SUCCEEDED);

      await persister.updateTrackInfo("123", TRACK_INFO_PARAMS);
      expect(axios.post).toHaveBeenCalledTimes(0);
      expect(persister.pendingUpdates).toEqual([]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(null);
    });

    it("should retry sending pending updates on a timer", async () => {
      const persister = new UpdatePersister();
      persister.setAuthToken("mock-token");
      persister.setHasLibraryMetadata(true);
      (library().getTrackUserChanges as Mock).mockReturnValue(true);

      // fails on first attempt
      (axios.post as Mock).mockRejectedValueOnce(new Error("Network error"));
      await persister.updateTrackInfo("123", TRACK_INFO_PARAMS);
      expect(persister.pendingUpdates).toEqual([TRACK_INFO_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
        TRACK_INFO_UPDATE_ARR_STR
      );
      expectTrackInfoPostRequest("123", TRACK_INFO_PARAMS);
      clearPostMock();

      // fails on second attempt
      (axios.post as Mock).mockRejectedValueOnce(OPERATION_FAILED);
      vi.runOnlyPendingTimers();
      await waitForUpdatesToFinish(persister);
      expect(persister.pendingUpdates).toEqual([TRACK_INFO_UPDATE]);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
        TRACK_INFO_UPDATE_ARR_STR
      );
      expectTrackInfoPostRequest("123", TRACK_INFO_PARAMS);
      clearPostMock();

      // succeeds on third attempt
      (axios.post as Mock).mockResolvedValueOnce(OPERATION_SUCCEEDED);
      vi.runOnlyPendingTimers();
      await waitForUpdatesToFinish(persister);

      expectTrackInfoPostRequest("123", TRACK_INFO_PARAMS);
      expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe("[]");
      expect(persister.pendingUpdates).toEqual([]);
    });
  });

  it("should support intermittent failing requests and adding while attempting updates", async () => {
    const updates: Update[] = [
      { type: "play", trackId: "123", params: undefined },
      { type: "rating", trackId: "456", params: { rating: 60 } },
      { type: "track-info", trackId: "789", params: TRACK_INFO_PARAMS },
    ];
    localStorage.setItem(LOCAL_STORAGE_KEY, JSON.stringify(updates));
    updates.push({ type: "play", trackId: "abc", params: undefined });
    const persister = new UpdatePersister();
    (library().getTrackUserChanges as Mock).mockReturnValue(true);

    // first attempt: only 456 succeeds
    (axios.post as Mock).mockRejectedValueOnce(new Error("Network error"));
    (axios.post as Mock).mockResolvedValueOnce(OPERATION_SUCCEEDED);
    (axios.post as Mock).mockRejectedValueOnce(new Error("Network error"));
    (axios.post as Mock).mockRejectedValueOnce(new Error("Network error"));
    persister.setAuthToken("mock-token");
    persister.setHasLibraryMetadata(true);
    persister.addPlay("abc"); // add another one, why not
    await waitForUpdatesToFinish(persister);
    expectPlayPostRequest("123");
    expectRatingPostRequest("456", 60);
    expectTrackInfoPostRequest("789", TRACK_INFO_PARAMS);
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

    // second attempt: only abc succeeds
    (axios.post as Mock).mockRejectedValueOnce(new Error("Network error"));
    (axios.post as Mock).mockRejectedValueOnce(OPERATION_FAILED);
    (axios.post as Mock).mockResolvedValueOnce(OPERATION_SUCCEEDED);
    persister.setAuthToken("mock-token");
    await waitForUpdatesToFinish(persister);
    expectPlayPostRequest("123");
    expectTrackInfoPostRequest("789", TRACK_INFO_PARAMS);
    expectPlayPostRequest("abc");
    clearPostMock();
    expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
      JSON.stringify([updates[0], updates[2]])
    );
    expect(persister.pendingUpdates).toEqual([updates[0], updates[2]]);

    // third attempt: only 123 succeeds
    (axios.post as Mock).mockResolvedValueOnce(OPERATION_SUCCEEDED);
    (axios.post as Mock).mockRejectedValueOnce(new Error("Network error"));
    persister.setAuthToken("mock-token");
    await waitForUpdatesToFinish(persister);
    expectPlayPostRequest("123");
    expectTrackInfoPostRequest("789", TRACK_INFO_PARAMS);
    clearPostMock();
    expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
      JSON.stringify([updates[2]])
    );
    expect(persister.pendingUpdates).toEqual([updates[2]]);

    // fourth attempt: 789 succeeds
    (axios.post as Mock).mockResolvedValueOnce(OPERATION_SUCCEEDED);
    persister.setAuthToken("mock-token");
    await waitForUpdatesToFinish(persister);
    expectTrackInfoPostRequest("789", TRACK_INFO_PARAMS);
    clearPostMock();
    expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe("[]");
    expect(persister.pendingUpdates).toEqual([]);
  });
});
