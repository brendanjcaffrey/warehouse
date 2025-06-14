import { describe, it, expect, vi, beforeEach, afterEach, Mock } from "vitest";
import { DownloadManager } from "../src/DownloadManager";
import { files } from "../src/Files";
import library from "../src/Library";
import {
  FileType,
  FileRequestSource,
  TrackFileIds,
  FileFetchedMessage,
  FileDownloadStatusMessage,
  DownloadStatus,
  FILE_FETCHED_TYPE,
  FILE_DOWNLOAD_STATUS_TYPE,
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
  MockLibrary.prototype.setInitializedListener = vi.fn();
  MockLibrary.prototype.getMusicIds = vi.fn();
  MockLibrary.prototype.getTrackMusicIds = vi.fn();
  MockLibrary.prototype.getArtworkIds = vi.fn();
  MockLibrary.prototype.getTrackArtworkIds = vi.fn();

  const mockLibrary = new MockLibrary();
  return {
    default: vi.fn(() => mockLibrary),
  };
});

vi.stubGlobal("postMessage", vi.fn());

const TEST_FILE_DATA = {
  data: "hi",
};

const FILE_123: TrackFileIds = { trackId: "t1", fileId: "123" };
const FILE_456: TrackFileIds = { trackId: "t2", fileId: "456" };
const FILE_789: TrackFileIds = { trackId: "t3", fileId: "789" };
const FILE_ABC: TrackFileIds = { trackId: "t4", fileId: "abc" };
const FILE_DEF: TrackFileIds = { trackId: "t5", fileId: "def" };
const FILE_GHI: TrackFileIds = { trackId: "t6", fileId: "ghi" };
const FILE_JKL: TrackFileIds = { trackId: "t7", fileId: "jkl" };

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
  let setInitializedListenerCallback: () => Promise<void>;

  beforeEach(() => {
    downloadManager = new DownloadManager();

    // i feel like there should always only be one call here, but that's not true?
    const numCalls = (library().setInitializedListener as Mock).mock.calls
      .length;
    setInitializedListenerCallback = (library().setInitializedListener as Mock)
      .mock.calls[numCalls - 1][0];

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
        if (type === FileType.MUSIC) {
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
        if (type === FileType.MUSIC) {
          tracksExist.set(id, true);
        } else if (type === FileType.ARTWORK) {
          artworksExist.set(id, true);
        }
        return true;
      }
    );
    (files().tryDeleteFile as Mock).mockImplementation(
      (type: FileType, id: string) => {
        if (type === FileType.MUSIC) {
          tracksExist.set(id, false);
        } else if (type === FileType.ARTWORK) {
          artworksExist.set(id, false);
        }
        return true;
      }
    );
    (files().getAllOfType as Mock).mockImplementation((type: FileType) => {
      if (type === FileType.MUSIC) {
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

  // don't call this directly, use the more specific ones below
  function _expectFileInProgressPostMessageCalls(
    fileType: FileType,
    ids: TrackFileIds
  ) {
    expect(postMessage).toHaveBeenCalledWith({
      type: FILE_DOWNLOAD_STATUS_TYPE,
      ids: ids,
      fileType: fileType,
      status: DownloadStatus.IN_PROGRESS,
      receivedBytes: 0,
      totalBytes: 0,
    } as FileDownloadStatusMessage);
  }

  // don't call this directly, use the more specific ones below
  function _expectFileDonePostMessageCalls(
    fileType: FileType,
    ids: TrackFileIds
  ) {
    expect(postMessage).toHaveBeenCalledWith({
      type: FILE_FETCHED_TYPE,
      fileType: fileType,
      ids: ids,
    } as FileFetchedMessage);
    expect(postMessage).toHaveBeenCalledWith({
      type: FILE_DOWNLOAD_STATUS_TYPE,
      ids: ids,
      fileType: fileType,
      status: DownloadStatus.DONE,
      receivedBytes: 0,
      totalBytes: 0,
    } as FileDownloadStatusMessage);
  }

  function expectOnlyFileInProgressPostMessageCalls(
    fileType: FileType,
    ids: TrackFileIds
  ) {
    expect(postMessage).toHaveBeenCalledTimes(1);
    _expectFileInProgressPostMessageCalls(fileType, ids);
    (postMessage as Mock).mockClear();
  }

  function expectOnlyFileDonePostMessageCalls(
    fileType: FileType,
    ids: TrackFileIds
  ) {
    expect(postMessage).toHaveBeenCalledTimes(2);
    _expectFileDonePostMessageCalls(fileType, ids);
    (postMessage as Mock).mockClear();
  }

  function expectFileDoneAndFileInProgressPostMessageCalls(
    fileType: FileType,
    doneIds: TrackFileIds,
    inProgressIds: TrackFileIds,
    inProgressFileType: FileType | undefined = undefined
  ) {
    expect(postMessage).toHaveBeenCalledTimes(3);
    _expectFileDonePostMessageCalls(fileType, doneIds);
    _expectFileInProgressPostMessageCalls(
      inProgressFileType || fileType,
      inProgressIds
    );
    (postMessage as Mock).mockClear();
  }

  function expectFileCanceledAndInProgressPostMessageCalls(
    fileType: FileType,
    canceledIds: TrackFileIds,
    inProgressIds: TrackFileIds
  ) {
    expect(postMessage).toHaveBeenCalledTimes(2);
    expect(postMessage).toHaveBeenCalledWith({
      type: FILE_DOWNLOAD_STATUS_TYPE,
      ids: canceledIds,
      fileType: fileType,
      status: DownloadStatus.CANCELED,
      receivedBytes: 0,
      totalBytes: 0,
    } as FileDownloadStatusMessage);
    _expectFileInProgressPostMessageCalls(fileType, inProgressIds);
    (postMessage as Mock).mockClear();
  }

  function expectOnlyFileErrorPostMessageCalls(
    fileType: FileType,
    ids: TrackFileIds
  ) {
    expect(postMessage).toHaveBeenCalledTimes(1);
    expect(postMessage).toHaveBeenCalledWith({
      type: FILE_DOWNLOAD_STATUS_TYPE,
      ids: ids,
      fileType: fileType,
      status: DownloadStatus.ERROR,
      receivedBytes: 0,
      totalBytes: 0,
    } as FileDownloadStatusMessage);
    (postMessage as Mock).mockClear();
  }

  function expectOnlyDownloadProgressPostMessageCalls(
    fileType: FileType,
    ids: TrackFileIds,
    loaded: number,
    total: number
  ) {
    expect(postMessage).toHaveBeenCalledTimes(1);
    expect(postMessage).toHaveBeenCalledWith({
      type: FILE_DOWNLOAD_STATUS_TYPE,
      ids: ids,
      fileType: fileType,
      status: DownloadStatus.IN_PROGRESS,
      receivedBytes: loaded,
      totalBytes: total,
    } as FileDownloadStatusMessage);
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

    expect(files().typeIsInitialized).toHaveBeenCalledWith(FileType.MUSIC);
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
      source: FileRequestSource.MUSIC_PRELOAD,
      fileType: FileType.MUSIC,
      ids: [FILE_123],
    });
    expect(files().fileExists).toHaveBeenCalledWith(FileType.MUSIC, "123");
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
      source: FileRequestSource.MUSIC_PRELOAD,
      fileType: FileType.MUSIC,
      ids: [FILE_123, FILE_456, FILE_789],
    });
    expectOnlyFileInProgressPostMessageCalls(FileType.MUSIC, FILE_456);

    // on setting source, should start fetching the first file, but the request hasn't resolved yet
    expectOneAxiosGetCall("/tracks/456");

    // make sure we don't start another request until the first one resolves
    await downloadManager.update();
    expect(axios.get).toHaveBeenCalledTimes(0);
    expect(files().tryWriteFile).toHaveBeenCalledTimes(0);

    // run the timer to resolve the first request, so we write the file and start the next request
    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.MUSIC, "456");
    expectFileDoneAndFileInProgressPostMessageCalls(
      FileType.MUSIC,
      FILE_456,
      FILE_789
    );
    expectOneAxiosGetCall("/tracks/789");

    // make sure we don't start another request until the first one resolves
    await downloadManager.update();
    expect(axios.get).toHaveBeenCalledTimes(0);
    expect(files().tryWriteFile).toHaveBeenCalledTimes(0);

    // resolve the second request - make sure we write the file and don't start another request
    await vi.advanceTimersToNextTimerAsync();
    expect(axios.get).toHaveBeenCalledTimes(0);
    expectOneTryWriteFileCall(FileType.MUSIC, "789");
    expectOnlyFileDonePostMessageCalls(FileType.MUSIC, FILE_789);
  });

  it("should fetch files 1 at a time for multiple sources", async () => {
    downloadManager.setAuthToken("test-token");
    mockFilesExistsAndWriteMethods();

    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 100);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 200);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 300);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 400);

    expect(postMessage).toHaveBeenCalledTimes(0);
    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.MUSIC_PRELOAD,
      fileType: FileType.MUSIC,
      ids: [FILE_123, FILE_456],
    });

    // on setting source, should start fetching the first file, but the request hasn't resolved yet
    expectOnlyFileInProgressPostMessageCalls(FileType.MUSIC, FILE_123);
    expectOneAxiosGetCall("/tracks/123");

    // make sure we don't start another request until the first one resolves
    await downloadManager.update();
    expect(axios.get).toHaveBeenCalledTimes(0);
    expect(files().tryWriteFile).toHaveBeenCalledTimes(0);
    expect(postMessage).toHaveBeenCalledTimes(0);

    // set a second source, which should start a new request
    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.ARTWORK_PRELOAD,
      fileType: FileType.ARTWORK,
      ids: [FILE_ABC, FILE_DEF],
    });
    expectOnlyFileInProgressPostMessageCalls(FileType.ARTWORK, FILE_ABC);
    expectOneAxiosGetCall("/artwork/abc");

    // run the timer to resolve the first track request, so we write the file and start the next track request
    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.MUSIC, "123");
    expectFileDoneAndFileInProgressPostMessageCalls(
      FileType.MUSIC,
      FILE_123,
      FILE_456
    );
    expectOneAxiosGetCall("/tracks/456");

    // make sure we don't start another request until the first one resolves
    await downloadManager.update();
    expect(axios.get).toHaveBeenCalledTimes(0);
    expect(files().tryWriteFile).toHaveBeenCalledTimes(0);

    // resolve the first artwork request - make sure we write the file and start another request
    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.ARTWORK, "abc");
    expectFileDoneAndFileInProgressPostMessageCalls(
      FileType.ARTWORK,
      FILE_ABC,
      FILE_DEF
    );
    expectOneAxiosGetCall("/artwork/def");

    // resolve the second track request - make sure we write the file and start another request
    await vi.advanceTimersToNextTimerAsync();
    expect(axios.get).toHaveBeenCalledTimes(0);
    expectOneTryWriteFileCall(FileType.MUSIC, "456");
    expectOnlyFileDonePostMessageCalls(FileType.MUSIC, FILE_456);

    // resolve the second artwork request - make sure we write the file and start another request
    await vi.advanceTimersToNextTimerAsync();
    expect(axios.get).toHaveBeenCalledTimes(0);
    expectOneTryWriteFileCall(FileType.ARTWORK, "def");
    expectOnlyFileDonePostMessageCalls(FileType.ARTWORK, FILE_DEF);
  });

  it("should leave the old request if the source changes with keep mode on", async () => {
    mockFilesExistsAndWriteMethods();
    downloadManager.setAuthToken("test-token");
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 100);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 200);

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.MUSIC_PRELOAD,
      fileType: FileType.MUSIC,
      ids: [FILE_123],
    });
    expect(files().fileExists).toHaveBeenCalledWith(FileType.MUSIC, "123");
    expectOnlyFileInProgressPostMessageCalls(FileType.MUSIC, FILE_123);
    expectOneAxiosGetCall("/tracks/123");

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.MUSIC_PRELOAD,
      fileType: FileType.MUSIC,
      ids: [FILE_456],
    });
    expect(files().fileExists).toHaveBeenCalledWith(FileType.MUSIC, "456");
    expectOnlyFileInProgressPostMessageCalls(FileType.MUSIC, FILE_456);
    expectOneAxiosGetCall("/tracks/456");

    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.MUSIC, "123");
    expectOnlyFileDonePostMessageCalls(FileType.MUSIC, FILE_123);

    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.MUSIC, "456");
    expectOnlyFileDonePostMessageCalls(FileType.MUSIC, FILE_456);
  });

  it("should cancel the old request if the source changes with keep mode off", async () => {
    downloadManager.setKeepMode(false);
    mockFilesExistsAndWriteMethods();
    downloadManager.setAuthToken("test-token");
    mockAxiosGetErrorAfterDelay("request canceled", 100);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 200);

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.MUSIC_PRELOAD,
      fileType: FileType.MUSIC,
      ids: [FILE_123],
    });
    expect(files().fileExists).toHaveBeenCalledWith(FileType.MUSIC, "123");
    const signal: AbortSignal = (axios.get as Mock).mock.calls[0][1].signal;
    expect(signal.aborted).toBe(false);
    expectOnlyFileInProgressPostMessageCalls(FileType.MUSIC, FILE_123);
    expectOneAxiosGetCall("/tracks/123");

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.MUSIC_PRELOAD,
      fileType: FileType.MUSIC,
      ids: [FILE_456],
    });
    expect(files().fileExists).toHaveBeenCalledWith(FileType.MUSIC, "456");
    expectFileCanceledAndInProgressPostMessageCalls(
      FileType.MUSIC,
      FILE_123,
      FILE_456
    );
    expectOneAxiosGetCall("/tracks/456");
    expect(signal.aborted).toBe(true);

    await vi.advanceTimersToNextTimerAsync();
    expect(files().tryWriteFile).toHaveBeenCalledTimes(0);

    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.MUSIC, "456");
    expectOnlyFileDonePostMessageCalls(FileType.MUSIC, FILE_456);
  });

  it("should cancel any old requests if keep mode is turned off", async () => {
    mockFilesExistsAndWriteMethods();
    downloadManager.setAuthToken("test-token");
    mockAxiosGetErrorAfterDelay("request canceled", 100);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 200);

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.MUSIC_PRELOAD,
      fileType: FileType.MUSIC,
      ids: [FILE_123],
    });
    expect(files().fileExists).toHaveBeenCalledWith(FileType.MUSIC, "123");
    const signal: AbortSignal = (axios.get as Mock).mock.calls[0][1].signal;
    expect(signal.aborted).toBe(false);
    expectOneAxiosGetCall("/tracks/123");
    expectOnlyFileInProgressPostMessageCalls(FileType.MUSIC, FILE_123);

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.MUSIC_PRELOAD,
      fileType: FileType.MUSIC,
      ids: [FILE_456],
    });
    expect(files().fileExists).toHaveBeenCalledWith(FileType.MUSIC, "456");
    expectOneAxiosGetCall("/tracks/456");
    expect(signal.aborted).toBe(false);

    await downloadManager.setKeepMode(false);
    expectFileCanceledAndInProgressPostMessageCalls(
      FileType.MUSIC,
      FILE_123,
      FILE_456
    );
    expect(signal.aborted).toBe(true);

    await vi.advanceTimersToNextTimerAsync();
    expect(files().tryWriteFile).toHaveBeenCalledTimes(0);

    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.MUSIC, "456");
    expectOnlyFileDonePostMessageCalls(FileType.MUSIC, FILE_456);
  });

  it("should retry on request failures with backoff", async () => {
    mockFilesExistsAndWriteMethods();
    downloadManager.setAuthToken("test-token");
    mockAxiosGetErrorAfterDelay("request canceled", 100);
    mockAxiosGetErrorAfterDelay("request canceled", 200);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 400);

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.MUSIC_PRELOAD,
      fileType: FileType.MUSIC,
      ids: [FILE_123, FILE_456],
    });
    expect(files().fileExists).toHaveBeenCalledWith(FileType.MUSIC, "123");
    expectOnlyFileInProgressPostMessageCalls(FileType.MUSIC, FILE_123);
    expectOneAxiosGetCall("/tracks/123");

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.MUSIC_PRELOAD,
      fileType: FileType.MUSIC,
      ids: [FILE_456],
    });
    expect(files().fileExists).toHaveBeenCalledWith(FileType.MUSIC, "456");
    expectOnlyFileInProgressPostMessageCalls(FileType.MUSIC, FILE_456);
    expectOneAxiosGetCall("/tracks/456");

    // 123 reqquest failed, don't retry
    await vi.advanceTimersToNextTimerAsync();
    expect(files().tryWriteFile).toHaveBeenCalledTimes(0);
    expect(axios.get).toHaveBeenCalledTimes(0);
    expectOnlyFileErrorPostMessageCalls(FileType.MUSIC, FILE_123);

    // 456 request failed, don't retry right away
    await vi.advanceTimersToNextTimerAsync();
    expect(files().tryWriteFile).toHaveBeenCalledTimes(0);
    expect(axios.get).toHaveBeenCalledTimes(0);
    expectOnlyFileErrorPostMessageCalls(FileType.MUSIC, FILE_456);

    // on timer, retry 456 request
    await vi.advanceTimersToNextTimerAsync();
    expectOnlyFileInProgressPostMessageCalls(FileType.MUSIC, FILE_456);
    expectOneAxiosGetCall("/tracks/456");

    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.MUSIC, "456");
    expectOnlyFileDonePostMessageCalls(FileType.MUSIC, FILE_456);
  });

  it("should post progress messages while the request is running", async () => {
    mockFilesExistsAndWriteMethods();
    downloadManager.setAuthToken("test-token");
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 100);

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.MUSIC_PRELOAD,
      fileType: FileType.MUSIC,
      ids: [FILE_123],
    });
    expect(files().fileExists).toHaveBeenCalledWith(FileType.MUSIC, "123");
    expectOnlyFileInProgressPostMessageCalls(FileType.MUSIC, FILE_123);
    const onDownloadProgress = (axios.get as Mock).mock.calls[0][1]
      .onDownloadProgress;
    expectOneAxiosGetCall("/tracks/123");

    onDownloadProgress({ loaded: 10, total: 100 });
    expectOnlyDownloadProgressPostMessageCalls(
      FileType.MUSIC,
      FILE_123,
      10,
      100
    );

    onDownloadProgress({ loaded: 20, total: 100 });
    expectOnlyDownloadProgressPostMessageCalls(
      FileType.MUSIC,
      FILE_123,
      20,
      100
    );

    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.MUSIC, "123");
    expectOnlyFileDonePostMessageCalls(FileType.MUSIC, FILE_123);
  });

  it("should delete any unneeded files when a library sync finishes", async () => {
    (files().getAllOfType as Mock).mockImplementation((type: FileType) => {
      if (type === FileType.MUSIC) {
        return new Set(["123", "456", "789"]);
      } else if (type === FileType.ARTWORK) {
        return new Set(["abc", "def", "ghi"]);
      } else {
        return new Set();
      }
    });
    (library().getMusicIds as Mock).mockReturnValue(new Set(["123", "789"]));
    (library().getArtworkIds as Mock).mockReturnValue(new Set(["abc", "ghi"]));
    await downloadManager.syncSucceeded();

    expect(files().tryDeleteFile).toHaveBeenCalledTimes(2);
    expect(files().tryDeleteFile).toHaveBeenCalledWith(FileType.MUSIC, "456");
    expect(files().tryDeleteFile).toHaveBeenCalledWith(FileType.ARTWORK, "def");
  });

  it("should delete any unneeded files when keep mode is turned off", async () => {
    downloadManager.setAuthToken("test-token");
    mockFilesExistsAndWriteMethods();

    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 100);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 200);

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.MUSIC_PRELOAD,
      fileType: FileType.MUSIC,
      ids: [FILE_123],
    });
    await vi.advanceTimersToNextTimerAsync();

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.MUSIC_PRELOAD,
      fileType: FileType.MUSIC,
      ids: [FILE_456],
    });
    await vi.advanceTimersToNextTimerAsync();
    expect(files().tryDeleteFile).toHaveBeenCalledTimes(0);

    await downloadManager.setKeepMode(false);
    expectOneTryDeleteFileCall(FileType.MUSIC, "123");
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
      source: FileRequestSource.MUSIC_PRELOAD,
      fileType: FileType.MUSIC,
      ids: [FILE_123],
    });
    await vi.advanceTimersToNextTimerAsync();

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.ARTWORK_PRELOAD,
      fileType: FileType.ARTWORK,
      ids: [FILE_ABC],
    });
    await vi.advanceTimersToNextTimerAsync();

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.MUSIC_PRELOAD,
      fileType: FileType.MUSIC,
      ids: [FILE_456],
    });
    expectOneTryDeleteFileCall(FileType.MUSIC, "123");
    await vi.advanceTimersToNextTimerAsync();

    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.ARTWORK_PRELOAD,
      fileType: FileType.ARTWORK,
      ids: [FILE_DEF],
    });
    expectOneTryDeleteFileCall(FileType.ARTWORK, "abc");
    await vi.advanceTimersToNextTimerAsync();
  });

  it("should download all files one by one when download mode is turned on", async () => {
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 100);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 200);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 300);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 400);

    downloadManager.setAuthToken("test-token");
    mockFilesExistsAndWriteMethods();
    await downloadManager.setKeepMode(true);
    await downloadManager.setDownloadMode(true);

    (library().getTrackMusicIds as Mock).mockReturnValue([
      FILE_123,
      FILE_456,
      FILE_789,
    ]);
    (library().getTrackArtworkIds as Mock).mockReturnValue([
      FILE_ABC,
      FILE_DEF,
      FILE_GHI,
      FILE_JKL,
    ]);

    tracksExist.set("456", true);
    artworksExist.set("abc", true);
    artworksExist.set("jkl", true);

    await setInitializedListenerCallback();
    expectOnlyFileInProgressPostMessageCalls(FileType.MUSIC, FILE_123);
    expectOneAxiosGetCall("/tracks/123");

    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.MUSIC, "123");
    expectOneAxiosGetCall("/tracks/789");
    expectFileDoneAndFileInProgressPostMessageCalls(
      FileType.MUSIC,
      FILE_123,
      FILE_789
    );

    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.MUSIC, "789");
    expectOneAxiosGetCall("/artwork/def");
    expectFileDoneAndFileInProgressPostMessageCalls(
      FileType.MUSIC,
      FILE_789,
      FILE_DEF,
      FileType.ARTWORK
    );

    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.ARTWORK, "def");
    expectOneAxiosGetCall("/artwork/ghi");
    expectFileDoneAndFileInProgressPostMessageCalls(
      FileType.ARTWORK,
      FILE_DEF,
      FILE_GHI
    );

    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.ARTWORK, "ghi");
    expectOnlyFileDonePostMessageCalls(FileType.ARTWORK, FILE_GHI);
  });

  it("should only download files in download mode when there are no other pre-load requests pending", async () => {
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 100);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 200);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 300);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 400);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 500);

    // first, download the abc file in download mode
    downloadManager.setAuthToken("test-token");
    mockFilesExistsAndWriteMethods();
    await downloadManager.setKeepMode(true);
    await downloadManager.setDownloadMode(true);
    (library().getTrackMusicIds as Mock).mockReturnValue([
      FILE_ABC,
      FILE_123,
      FILE_456,
      FILE_789,
      FILE_DEF,
    ]);
    (library().getTrackArtworkIds as Mock).mockReturnValue([]);
    await setInitializedListenerCallback();
    expectOnlyFileInProgressPostMessageCalls(FileType.MUSIC, FILE_ABC);
    expectOneAxiosGetCall("/tracks/abc");

    // then we set a non-download mode source, all those files should get downloaded next
    await downloadManager.setSourceRequestedFiles({
      type: "",
      source: FileRequestSource.MUSIC_PRELOAD,
      fileType: FileType.MUSIC,
      ids: [FILE_123, FILE_456, FILE_789],
    });
    expectOnlyFileInProgressPostMessageCalls(FileType.MUSIC, FILE_123);
    expectOneAxiosGetCall("/tracks/123");

    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.MUSIC, "abc");
    expectOnlyFileDonePostMessageCalls(FileType.MUSIC, FILE_ABC);

    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.MUSIC, "123");
    expectOneAxiosGetCall("/tracks/456");
    expectFileDoneAndFileInProgressPostMessageCalls(
      FileType.MUSIC,
      FILE_123,
      FILE_456
    );

    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.MUSIC, "456");
    expectOneAxiosGetCall("/tracks/789");
    expectFileDoneAndFileInProgressPostMessageCalls(
      FileType.MUSIC,
      FILE_456,
      FILE_789
    );

    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.MUSIC, "789");
    expectOneAxiosGetCall("/tracks/def");
    expectFileDoneAndFileInProgressPostMessageCalls(
      FileType.MUSIC,
      FILE_789,
      FILE_DEF
    );

    // finish download mode
    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.MUSIC, "def");
    expectOnlyFileDonePostMessageCalls(FileType.MUSIC, FILE_DEF);
  });

  it("should allow any download requests to finish but not start any more when download mode is turned off", async () => {
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 100);
    mockAxiosGetResolveAfterDelay(TEST_FILE_DATA, 200);

    downloadManager.setAuthToken("test-token");
    mockFilesExistsAndWriteMethods();
    await downloadManager.setKeepMode(true);
    await downloadManager.setDownloadMode(true);

    (library().getTrackMusicIds as Mock).mockReturnValue([
      FILE_123,
      FILE_456,
      FILE_789,
      FILE_ABC,
    ]);
    (library().getTrackArtworkIds as Mock).mockReturnValue([]);

    await setInitializedListenerCallback();
    expectOnlyFileInProgressPostMessageCalls(FileType.MUSIC, FILE_123);
    expectOneAxiosGetCall("/tracks/123");

    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.MUSIC, "123");
    expectOneAxiosGetCall("/tracks/456");
    expectFileDoneAndFileInProgressPostMessageCalls(
      FileType.MUSIC,
      FILE_123,
      FILE_456
    );

    await downloadManager.setDownloadMode(false);

    await vi.advanceTimersToNextTimerAsync();
    expectOneTryWriteFileCall(FileType.MUSIC, "456");
    expectOnlyFileDonePostMessageCalls(FileType.MUSIC, FILE_456);
  });
});
