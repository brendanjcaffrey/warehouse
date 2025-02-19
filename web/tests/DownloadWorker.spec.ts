import { describe, it, expect, vi, beforeEach, afterEach, Mock } from "vitest";
import { DownloadManager } from "../src/DownloadWorker";
import { files } from "../src/Files";
import library from "../src/Library";
import {
  FileType,
  FileRequestSource,
  FILE_FETCHED_TYPE,
} from "../src/WorkerTypes";
import axios from "axios";

vi.mock("axios");

vi.mock("../src/Files", () => {
  const MockFiles = vi.fn();
  MockFiles.prototype.typeIsInitialized = vi.fn();
  MockFiles.prototype.fileExists = vi.fn();
  MockFiles.prototype.tryWriteFile = vi.fn();
  MockFiles.prototype.getAllOfType = vi.fn();
  MockFiles.prototype.tryDeleteFile = vi.fn();

  const mockFiles = new MockFiles();
  return {
    files: vi.fn(() => mockFiles),
  };
});

vi.mock("../src/Library", () => {
  const MockLibrary = vi.fn();
  MockLibrary.prototype.getTrackIds = vi.fn();
  MockLibrary.prototype.getArtworkIds = vi.fn();

  const mockLibrary = new MockLibrary();
  return {
    default: vi.fn(() => mockLibrary),
  };
});

vi.stubGlobal("postMessage", vi.fn());

const TEST_FILE_DATA = {
  data: "hi",
};

function mockAxiosGetResolveAfterDelay<T>(data: T, delayMs: number) {
  (axios.get as Mock).mockImplementationOnce(() => {
    return new Promise((resolve) => {
      setTimeout(() => {
        resolve(data);
      }, delayMs);
    });
  });
}

function mockAxiosGetErrorAfterDelay<T>(data: T, delayMs: number) {
  (axios.get as Mock).mockImplementationOnce(() => {
    return new Promise((_, reject) => {
      setTimeout(() => {
        reject(data);
      }, delayMs);
    });
  });
}

describe("DownloadManager", () => {
  let downloadManager: DownloadManager;
  let tracksExist: Map<string, boolean>;
  let artworksExist: Map<string, boolean>;

  beforeEach(() => {
    downloadManager = new DownloadManager();
    tracksExist = new Map<string, boolean>();
    artworksExist = new Map<string, boolean>();
    vi.clearAllMocks();
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.clearAllTimers();
  });

  function mockFilesExistsAndWriteMethods() {
    (files().typeIsInitialized as Mock).mockReturnValue(true);
    (files().fileExists as Mock).mockImplementation(
      (type: FileType, id: string) => {
        if (type === FileType.TRACK) {
          return tracksExist.get(id) || false;
        } else if (type === FileType.ARTWORK) {
          return artworksExist.get(id) || false;
        } else {
          return false;
        }
      }
    );
    (files().tryWriteFile as Mock).mockImplementation(
      (type: FileType, id: string) => {
        if (type === FileType.TRACK) {
          tracksExist.set(id, true);
        } else if (type === FileType.ARTWORK) {
          artworksExist.set(id, true);
        }
        return true;
      }
    );
    (files().tryDeleteFile as Mock).mockImplementation(
      (type: FileType, id: string) => {
        if (type === FileType.TRACK) {
          tracksExist.set(id, false);
        } else if (type === FileType.ARTWORK) {
          artworksExist.set(id, false);
        }
        return true;
      }
    );
    (files().getAllOfType as Mock).mockImplementation((type: FileType) => {
      if (type === FileType.TRACK) {
        return [...tracksExist.entries()].filter(([, v]) => v).map(([k]) => k);
      } else if (type === FileType.ARTWORK) {
        return [...artworksExist.entries()]
          .filter(([, v]) => v)
          .map(([k]) => k);
      } else {
        return new Set();
      }
    });
  }

  function expectOneAxiosGetCall(path: string) {
    expect(axios.get).toHaveBeenCalledTimes(1);
    expect(axios.get).toHaveBeenCalledWith(
      path,
      expect.objectContaining({
        headers: expect.objectContaining({
          Authorization: "Bearer test-token",
        }),
        responseType: "arraybuffer",
      })
    );
    (axios.get as Mock).mockClear();
  }

  function expectOnePostMessageCall(fileType: FileType, id: string) {
    expect(postMessage).toHaveBeenCalledTimes(1);
    expect(postMessage).toHaveBeenCalledWith({
      type: FILE_FETCHED_TYPE,
      fileType: fileType,
      id: id,
    });
    (postMessage as Mock).mockClear();
  }

  function expectOneTryWriteFileCall(fileType: FileType, id: string) {
    expect(files().tryWriteFile).toHaveBeenCalledTimes(1);
    expect(files().tryWriteFile).toHaveBeenCalledWith(
      fileType,
      id,
      TEST_FILE_DATA.data
    );
    (files().tryWriteFile as Mock).mockClear();
  }

  function expectOneTryDeleteFileCall(fileType: FileType, id: string) {
    expect(files().tryDeleteFile).toHaveBeenCalledTimes(1);
    expect(files().tryDeleteFile).toHaveBeenCalledWith(fileType, id);
    (files().tryDeleteFile as Mock).mockClear();
  }

  it("should try updating over and over until the auth token is set and the files are all initialized", async () => {
    await downloadManager.update();
    expect(files().typeIsInitialized).not.toHaveBeenCalled();

    downloadManager.setAuthToken("test-token");
    (files().typeIsInitialized as Mock).mockReturnValueOnce(false);
    vi.runOnlyPendingTimersAsync();
    await vi.waitFor(async () => {
      if ((files().typeIsInitialized as Mock).mock.calls.length < 1) {
        throw new Error("waiting for 1 call");
      }
    });
    expect(files().typeIsInitialized).toHaveBeenCalledTimes(1);

    (files().typeIsInitialized as Mock).mockClear().mockReturnValue(true);
    vi.runOnlyPendingTimersAsync();
    await vi.waitFor(async () => {
      if ((files().typeIsInitialized as Mock).mock.calls.length < 2) {
        throw new Error("waiting for 2 calls");
      }
    });

    expect(files().typeIsInitialized).toHaveBeenCalledWith(FileType.TRACK);
    expect(files().typeIsInitialized).toHaveBeenCalledWith(FileType.ARTWORK);
  });

  it("should update when keepMode changes", () => {
    const updateSpy = vi.spyOn(downloadManager, "update");
    downloadManager.setKeepMode(false);
    expect(updateSpy).toHaveBeenCalled();
  });

  it("should not update if keepMode is unchanged", () => {
    const updateSpy = vi.spyOn(downloadManager, "update");
    downloadManager.setKeepMode(true);
    expect(updateSpy).not.toHaveBeenCalled();
  });

  it("should not start requests if file exists", async () => {
    downloadManager.setAuthToken("test-token");
    (files().typeIsInitialized as Mock).mockResolvedValue(true);
    (files().fileExists as Mock).mockResolvedValue(true);

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.TRACK_PRELOAD,
      fileType: FileType.TRACK,
      ids: ["123"],
    });
    expect(files().fileExists).toHaveBeenCalledWith(FileType.TRACK, "123");
  });

  it("should fetch files 1 at a time for one source", async () => {
    downloadManager.setAuthToken("test-token");
    mockFilesExistsAndWriteMethods();

    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 100);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 100);

    // should skip 123 if we say it already exists
    tracksExist.set("123", true);
    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.TRACK_PRELOAD,
      fileType: FileType.TRACK,
      ids: ["123", "456", "789"],
    });

    // on setting source, should start fetching the first file, but the request hasn't resolved yet
    expectOneAxiosGetCall("/tracks/456");

    // make sure we don't start another request until the first one resolves
    await downloadManager.update();
    expect(axios.get).toHaveBeenCalledTimes(0);
    expect(files().tryWriteFile).toHaveBeenCalledTimes(0);

    // run the timer to resolve the first request, so we write the file and start the next request
    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.TRACK, "456");
    expectOnePostMessageCall(FileType.TRACK, "456");
    expectOneAxiosGetCall("/tracks/789");

    // make sure we don't start another request until the first one resolves
    await downloadManager.update();
    expect(axios.get).toHaveBeenCalledTimes(0);
    expect(files().tryWriteFile).toHaveBeenCalledTimes(0);

    // resolve the second request - make sure we write the file and don't start another request
    await vi.advanceTimersToNextTimerAsync();
    expect(axios.get).toHaveBeenCalledTimes(0);
    expectOneTryWriteFileCall(FileType.TRACK, "789");
    expectOnePostMessageCall(FileType.TRACK, "789");
  });

  it("should fetch files 1 at a time for multiple sources", async () => {
    downloadManager.setAuthToken("test-token");
    mockFilesExistsAndWriteMethods();

    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 100);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 200);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 300);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 400);

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.TRACK_PRELOAD,
      fileType: FileType.TRACK,
      ids: ["123", "456"],
    });

    // on setting source, should start fetching the first file, but the request hasn't resolved yet
    expectOneAxiosGetCall("/tracks/123");

    // make sure we don't start another request until the first one resolves
    await downloadManager.update();
    expect(axios.get).toHaveBeenCalledTimes(0);
    expect(files().tryWriteFile).toHaveBeenCalledTimes(0);

    // set a second source, which should start a new request
    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.ARTWORK_PRELOAD,
      fileType: FileType.ARTWORK,
      ids: ["abc", "def"],
    });
    expectOneAxiosGetCall("/artwork/abc");

    // run the timer to resolve the first track request, so we write the file and start the next track request
    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.TRACK, "123");
    expectOnePostMessageCall(FileType.TRACK, "123");
    expectOneAxiosGetCall("/tracks/456");

    // make sure we don't start another request until the first one resolves
    await downloadManager.update();
    expect(axios.get).toHaveBeenCalledTimes(0);
    expect(files().tryWriteFile).toHaveBeenCalledTimes(0);

    // resolve the first artwork request - make sure we write the file and start another request
    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.ARTWORK, "abc");
    expectOnePostMessageCall(FileType.ARTWORK, "abc");
    expectOneAxiosGetCall("/artwork/def");

    // resolve the second track request - make sure we write the file and start another request
    await vi.advanceTimersToNextTimerAsync();
    expect(axios.get).toHaveBeenCalledTimes(0);
    expectOneTryWriteFileCall(FileType.TRACK, "456");
    expectOnePostMessageCall(FileType.TRACK, "456");

    // resolve the second artwork request - make sure we write the file and start another request
    await vi.advanceTimersToNextTimerAsync();
    expect(axios.get).toHaveBeenCalledTimes(0);
    expectOneTryWriteFileCall(FileType.ARTWORK, "def");
    expectOnePostMessageCall(FileType.ARTWORK, "def");
  });

  it("should leave the old request if the source changes with keep mode on", async () => {
    mockFilesExistsAndWriteMethods();
    downloadManager.setAuthToken("test-token");
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 100);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 200);

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.TRACK_PRELOAD,
      fileType: FileType.TRACK,
      ids: ["123"],
    });
    expect(files().fileExists).toHaveBeenCalledWith(FileType.TRACK, "123");
    expectOneAxiosGetCall("/tracks/123");

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.TRACK_PRELOAD,
      fileType: FileType.TRACK,
      ids: ["456"],
    });
    expect(files().fileExists).toHaveBeenCalledWith(FileType.TRACK, "456");
    expectOneAxiosGetCall("/tracks/456");

    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.TRACK, "123");
    expectOnePostMessageCall(FileType.TRACK, "123");

    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.TRACK, "456");
    expectOnePostMessageCall(FileType.TRACK, "456");
  });

  it("should cancel the old request if the source changes with keep mode off", async () => {
    downloadManager.setKeepMode(false);
    mockFilesExistsAndWriteMethods();
    downloadManager.setAuthToken("test-token");
    mockAxiosGetErrorAfterDelay("request canceled", 100);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 200);

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.TRACK_PRELOAD,
      fileType: FileType.TRACK,
      ids: ["123"],
    });
    expect(files().fileExists).toHaveBeenCalledWith(FileType.TRACK, "123");
    const signal: AbortSignal = (axios.get as Mock).mock.calls[0][1].signal;
    expect(signal.aborted).toBe(false);
    expectOneAxiosGetCall("/tracks/123");

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.TRACK_PRELOAD,
      fileType: FileType.TRACK,
      ids: ["456"],
    });
    expect(files().fileExists).toHaveBeenCalledWith(FileType.TRACK, "456");
    expectOneAxiosGetCall("/tracks/456");
    expect(signal.aborted).toBe(true);

    await vi.advanceTimersToNextTimerAsync();
    expect(files().tryWriteFile).toHaveBeenCalledTimes(0);

    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.TRACK, "456");
    expectOnePostMessageCall(FileType.TRACK, "456");
  });

  it("should cancel any old requests if keep mode is turned off", async () => {
    mockFilesExistsAndWriteMethods();
    downloadManager.setAuthToken("test-token");
    mockAxiosGetErrorAfterDelay("request canceled", 100);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 200);

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.TRACK_PRELOAD,
      fileType: FileType.TRACK,
      ids: ["123"],
    });
    expect(files().fileExists).toHaveBeenCalledWith(FileType.TRACK, "123");
    const signal: AbortSignal = (axios.get as Mock).mock.calls[0][1].signal;
    expect(signal.aborted).toBe(false);
    expectOneAxiosGetCall("/tracks/123");

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.TRACK_PRELOAD,
      fileType: FileType.TRACK,
      ids: ["456"],
    });
    expect(files().fileExists).toHaveBeenCalledWith(FileType.TRACK, "456");
    expectOneAxiosGetCall("/tracks/456");
    expect(signal.aborted).toBe(false);

    await downloadManager.setKeepMode(false);
    expect(signal.aborted).toBe(true);

    await vi.advanceTimersToNextTimerAsync();
    expect(files().tryWriteFile).toHaveBeenCalledTimes(0);

    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.TRACK, "456");
    expectOnePostMessageCall(FileType.TRACK, "456");
  });

  it("should retry on request failures with backoff", async () => {
    mockFilesExistsAndWriteMethods();
    downloadManager.setAuthToken("test-token");
    mockAxiosGetErrorAfterDelay("request canceled", 100);
    mockAxiosGetErrorAfterDelay("request canceled", 200);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 400);

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.TRACK_PRELOAD,
      fileType: FileType.TRACK,
      ids: ["123", "456"],
    });
    expect(files().fileExists).toHaveBeenCalledWith(FileType.TRACK, "123");
    expectOneAxiosGetCall("/tracks/123");

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.TRACK_PRELOAD,
      fileType: FileType.TRACK,
      ids: ["456"],
    });
    expect(files().fileExists).toHaveBeenCalledWith(FileType.TRACK, "456");
    expectOneAxiosGetCall("/tracks/456");

    // 123 reqquest failed, don't retry
    await vi.advanceTimersToNextTimerAsync();
    expect(files().tryWriteFile).toHaveBeenCalledTimes(0);
    expect(axios.get).toHaveBeenCalledTimes(0);

    // 456 request failed, don't retry right away
    await vi.advanceTimersToNextTimerAsync();
    expect(files().tryWriteFile).toHaveBeenCalledTimes(0);
    expect(axios.get).toHaveBeenCalledTimes(0);

    // on timer, retry 456 request
    await vi.advanceTimersToNextTimerAsync();
    expectOneAxiosGetCall("/tracks/456");

    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.TRACK, "456");
    expectOnePostMessageCall(FileType.TRACK, "456");
  });

  it("should delete any unneeded files when a library sync finishes", async () => {
    (files().getAllOfType as Mock).mockImplementation((type: FileType) => {
      if (type === FileType.TRACK) {
        return new Set(["123", "456", "789"]);
      } else if (type === FileType.ARTWORK) {
        return new Set(["abc", "def", "ghi"]);
      } else {
        return new Set();
      }
    });
    (library().getTrackIds as Mock).mockReturnValue(new Set(["123", "789"]));
    (library().getArtworkIds as Mock).mockReturnValue(new Set(["abc", "ghi"]));
    await downloadManager.syncSucceeded();

    expect(files().tryDeleteFile).toHaveBeenCalledTimes(2);
    expect(files().tryDeleteFile).toHaveBeenCalledWith(FileType.TRACK, "456");
    expect(files().tryDeleteFile).toHaveBeenCalledWith(FileType.ARTWORK, "def");
  });

  it("should delete any unneeded files when keep mode is turned off", async () => {
    downloadManager.setAuthToken("test-token");
    mockFilesExistsAndWriteMethods();

    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 100);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 200);

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.TRACK_PRELOAD,
      fileType: FileType.TRACK,
      ids: ["123"],
    });
    await vi.advanceTimersToNextTimerAsync();

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.TRACK_PRELOAD,
      fileType: FileType.TRACK,
      ids: ["456"],
    });
    await vi.advanceTimersToNextTimerAsync();
    expect(files().tryDeleteFile).toHaveBeenCalledTimes(0);

    await downloadManager.setKeepMode(false);
    expectOneTryDeleteFileCall(FileType.TRACK, "123");
  });

  it("should delete any unneeded files when keep mode is off and a source changes", async () => {
    downloadManager.setAuthToken("test-token");
    mockFilesExistsAndWriteMethods();
    await downloadManager.setKeepMode(false);

    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 100);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 200);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 300);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 300);

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.TRACK_PRELOAD,
      fileType: FileType.TRACK,
      ids: ["123"],
    });
    await vi.advanceTimersToNextTimerAsync();

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.ARTWORK_PRELOAD,
      fileType: FileType.ARTWORK,
      ids: ["abc"],
    });
    await vi.advanceTimersToNextTimerAsync();

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.TRACK_PRELOAD,
      fileType: FileType.TRACK,
      ids: ["456"],
    });
    expectOneTryDeleteFileCall(FileType.TRACK, "123");
    await vi.advanceTimersToNextTimerAsync();

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.ARTWORK_PRELOAD,
      fileType: FileType.ARTWORK,
      ids: ["def"],
    });
    expectOneTryDeleteFileCall(FileType.ARTWORK, "abc");
    await vi.advanceTimersToNextTimerAsync();
  });
});
