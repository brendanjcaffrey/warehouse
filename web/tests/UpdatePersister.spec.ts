import { describe, it, expect, vi, beforeEach, Mock } from "vitest";
import axios from "axios";
import { UpdatePersister, Update } from "../src/UpdatePersister";

vi.mock("axios");

function expectPlayPostRequest(id: string) {
  expect(axios.post).toHaveBeenCalledWith(
    `/api/play/${id}`,
    undefined,
    expect.objectContaining({ headers: { Authorization: "Bearer mock-token" } })
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
  const PLAY_UPDATE: Update = {
    type: "play",
    trackId: "123",
    params: undefined,
  };
  const PLAY_UPDATE_ARR_STR = JSON.stringify([PLAY_UPDATE]);

  beforeEach(() => {
    localStorage.clear();
    vi.useFakeTimers();
    vi.clearAllMocks();
    vi.clearAllTimers();
  });

  it("should initialize with no pending updates if local storage key doesn't exist", () => {
    const persister = new UpdatePersister();
    expect(persister.pendingUpdates).toEqual([]);
    expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBeNull();
  });

  it("should initialize with pending updates from local storage if they exist", () => {
    localStorage.setItem(LOCAL_STORAGE_KEY, PLAY_UPDATE_ARR_STR);
    const persister = new UpdatePersister();
    expect(persister.pendingUpdates).toEqual([PLAY_UPDATE]);
  });

  it("should do nothing on auth token set if there's nothing pending", () => {
    const persister = new UpdatePersister();
    persister.setAuthToken("mock-token");
    expect(axios.post).not.toHaveBeenCalled();
  });

  it("should attempt any pending updates when the auth token is set", async () => {
    localStorage.setItem(LOCAL_STORAGE_KEY, PLAY_UPDATE_ARR_STR);

    const persister = new UpdatePersister();
    persister.setAuthToken("mock-token");
    expectPlayPostRequest("123");
  });

  it("should add a play update to pending updates & persist if not authenticated", async () => {
    const persister = new UpdatePersister();
    await persister.addPlay("123");

    expect(persister.pendingUpdates).toEqual([PLAY_UPDATE]);
    expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(PLAY_UPDATE_ARR_STR);
  });

  it("should add a play update and immediately attempt it if authenticated", async () => {
    const persister = new UpdatePersister();
    persister.setAuthToken("mock-token");
    (axios.post as Mock).mockResolvedValueOnce({});

    await persister.addPlay("123");
    expectPlayPostRequest("123");
    expect(persister.pendingUpdates).toEqual([]);
    expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(null);
  });

  it("should retry sending pending updates on a timer", async () => {
    const persister = new UpdatePersister();
    persister.setAuthToken("mock-token");

    // fails on first attempt
    (axios.post as Mock).mockRejectedValueOnce(new Error("Network error"));
    await persister.addPlay("123");
    expect(persister.pendingUpdates).toEqual([PLAY_UPDATE]);
    expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(PLAY_UPDATE_ARR_STR);
    expectPlayPostRequest("123");
    clearPostMock();

    // fails on second attempt
    (axios.post as Mock).mockRejectedValueOnce(new Error("Network error"));
    vi.runOnlyPendingTimers();
    await waitForUpdatesToFinish(persister);
    expect(persister.pendingUpdates).toEqual([PLAY_UPDATE]);
    expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(PLAY_UPDATE_ARR_STR);
    expectPlayPostRequest("123");
    clearPostMock();

    // succeeds on third attempt
    (axios.post as Mock).mockResolvedValueOnce({});
    vi.runOnlyPendingTimers();
    await waitForUpdatesToFinish(persister);

    expectPlayPostRequest("123");
    expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe("[]");
    expect(persister.pendingUpdates).toEqual([]);
  });

  it("should support intermittent failing requests and adding while attempting updates", async () => {
    const updates: Update[] = [
      { type: "play", trackId: "123", params: undefined },
      { type: "play", trackId: "456", params: undefined },
      { type: "play", trackId: "789", params: undefined },
    ];
    localStorage.setItem(LOCAL_STORAGE_KEY, JSON.stringify(updates));
    updates.push({ type: "play", trackId: "abc", params: undefined });
    const persister = new UpdatePersister();

    // first attempt: only 456 succeeds
    (axios.post as Mock).mockRejectedValueOnce(new Error("Network error"));
    (axios.post as Mock).mockResolvedValueOnce({});
    (axios.post as Mock).mockRejectedValueOnce(new Error("Network error"));
    (axios.post as Mock).mockRejectedValueOnce(new Error("Network error"));
    persister.setAuthToken("mock-token");
    persister.addPlay("abc"); // add another one, why not
    await waitForUpdatesToFinish(persister);
    expectPlayPostRequest("123");
    expectPlayPostRequest("456");
    expectPlayPostRequest("789");
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
    (axios.post as Mock).mockRejectedValueOnce(new Error("Network error"));
    (axios.post as Mock).mockResolvedValueOnce({});
    persister.setAuthToken("mock-token");
    await waitForUpdatesToFinish(persister);
    expectPlayPostRequest("123");
    expectPlayPostRequest("789");
    expectPlayPostRequest("abc");
    clearPostMock();
    expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
      JSON.stringify([updates[0], updates[2]])
    );
    expect(persister.pendingUpdates).toEqual([updates[0], updates[2]]);

    // third attempt: only 123 succeeds
    (axios.post as Mock).mockResolvedValueOnce({});
    (axios.post as Mock).mockRejectedValueOnce(new Error("Network error"));
    persister.setAuthToken("mock-token");
    await waitForUpdatesToFinish(persister);
    expectPlayPostRequest("123");
    expectPlayPostRequest("789");
    clearPostMock();
    expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe(
      JSON.stringify([updates[2]])
    );
    expect(persister.pendingUpdates).toEqual([updates[2]]);

    // fourth attempt: 789 succeeds
    (axios.post as Mock).mockResolvedValueOnce({});
    persister.setAuthToken("mock-token");
    await waitForUpdatesToFinish(persister);
    expectPlayPostRequest("789");
    clearPostMock();
    expect(localStorage.getItem(LOCAL_STORAGE_KEY)).toBe("[]");
    expect(persister.pendingUpdates).toEqual([]);
  });
});
