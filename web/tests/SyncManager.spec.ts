import { describe, it, expect, vi, beforeEach } from "vitest";
import { SyncManager } from "../src/SyncManager";
import {
  Library,
  Name,
  SortName,
  Track,
  Playlist,
  VersionResponse,
  LibraryResponse,
} from "../src/generated/messages";
import library from "../src/Library";
import axios, { isAxiosError } from "axios";
import {
  ERROR_TYPE,
  ErrorMessage,
  LIBRARY_METADATA_TYPE,
  LibraryMetadataMessage,
  SYNC_SUCCEEDED_TYPE,
  TypedMessage,
} from "../src/WorkerTypes";

vi.mock("axios", () => ({
  default: {
    get: vi.fn(),
  },
  isAxiosError: vi.fn(),
}));

vi.mock("../src/Library", () => {
  const MockLibrary = vi.fn();
  MockLibrary.prototype.clear = vi.fn();
  MockLibrary.prototype.putTrack = vi.fn();
  MockLibrary.prototype.putPlaylist = vi.fn();

  const mockLibrary = new MockLibrary();
  return {
    default: vi.fn(() => mockLibrary),
  };
});

vi.stubGlobal("postMessage", vi.fn());

function mockAxiosGetResolve<T>(data: T) {
  vi.mocked(axios.get).mockImplementationOnce(() => {
    return Promise.resolve({ data });
  });
}

function mockAxiosGetError(code: string = "ERR_UNKNOWN") {
  vi.mocked(axios.get).mockImplementationOnce(() => {
    return Promise.reject({ message: "mock error", code: code });
  });
}

function expectAxiosGetCalls(paths: string[]) {
  expect(axios.get).toHaveBeenCalledTimes(paths.length);
  paths.forEach((path) => {
    expect(axios.get).toHaveBeenCalledWith(
      path,
      expect.objectContaining({
        headers: expect.objectContaining({
          Authorization: "Bearer test-token",
        }),
        responseType: "arraybuffer",
      })
    );
  });
  vi.mocked(axios.get).mockClear();
}

function expectSyncSucceededPostMessage() {
  expect(postMessage).toHaveBeenCalledWith({
    type: SYNC_SUCCEEDED_TYPE,
  } as TypedMessage);
}

function expectErrorPostMessage() {
  expect(postMessage).toHaveBeenCalledWith({
    type: ERROR_TYPE,
    error: "mock error",
  } as ErrorMessage);
}

describe("SyncManager", () => {
  let syncManager = new SyncManager();
  let genres = new Map<number, Name>();
  let artists = new Map<number, SortName>();
  let albums = new Map<number, SortName>();
  let tracks: Track[] = [];
  let playlists: Playlist[] = [];

  beforeEach(() => {
    vi.mocked(postMessage).mockClear();
    vi.mocked(axios.get).mockClear();
    vi.mocked(isAxiosError).mockClear();
  });

  function buildLibraryMsg(): Uint8Array {
    const library = new Library({
      genres,
      artists,
      albums,
      tracks,
      playlists,
      trackUserChanges: true,
      totalFileSize: 100,
      updateTimeNs: 200,
    });
    return new LibraryResponse({ library }).serialize();
  }

  it("should sync when the last update is 0", async () => {
    mockAxiosGetResolve(buildLibraryMsg());

    await syncManager.startSync("test-token", 0, true);
    expectAxiosGetCalls(["/api/library"]);
    expectSyncSucceededPostMessage();
  });

  it("should sync when the last update time is older", async () => {
    mockAxiosGetResolve(new VersionResponse({ updateTimeNs: 400 }).serialize());
    mockAxiosGetResolve(buildLibraryMsg());

    await syncManager.startSync("test-token", 200, true);
    expectAxiosGetCalls(["/api/version", "/api/library"]);
    expectSyncSucceededPostMessage();
  });

  it("should post an error when the sync request fails", async () => {
    mockAxiosGetResolve(new VersionResponse({ updateTimeNs: 400 }).serialize());
    mockAxiosGetError();

    await syncManager.startSync("test-token", 200, true);
    expectAxiosGetCalls(["/api/version", "/api/library"]);
    expectErrorPostMessage();
  });

  it("should post an error when the sync request returns an error", async () => {
    mockAxiosGetResolve(new VersionResponse({ updateTimeNs: 400 }).serialize());
    mockAxiosGetResolve(
      new LibraryResponse({ error: "mock error" }).serialize()
    );

    await syncManager.startSync("test-token", 200, true);
    expectAxiosGetCalls(["/api/version", "/api/library"]);
    expectErrorPostMessage();
  });

  it("should not sync when the last update time matches", async () => {
    mockAxiosGetResolve(new VersionResponse({ updateTimeNs: 400 }).serialize());

    await syncManager.startSync("test-token", 400, true);
    expectAxiosGetCalls(["/api/version"]);
    expectSyncSucceededPostMessage();
  });

  it("should post an error when the version request fails and the browser is online", async () => {
    mockAxiosGetError();
    vi.mocked(isAxiosError).mockReturnValue(true);

    await syncManager.startSync("test-token", 400, true);
    expectAxiosGetCalls(["/api/version"]);
    expectErrorPostMessage();
  });

  it("should post an error when the version request responds with an error and the browser is online", async () => {
    mockAxiosGetResolve(
      new VersionResponse({ error: "mock error" }).serialize()
    );
    vi.mocked(isAxiosError).mockReturnValue(false);

    await syncManager.startSync("test-token", 400, true);
    expectAxiosGetCalls(["/api/version"]);
    expectErrorPostMessage();
  });

  it("should not sync when there's an axios error and the browser is offline", async () => {
    mockAxiosGetError();
    vi.mocked(isAxiosError).mockReturnValue(true);

    await syncManager.startSync("test-token", 400, false);
    expectAxiosGetCalls(["/api/version"]);
    expectSyncSucceededPostMessage();
  });

  it("should not sync when there's an axios error with a network error code", async () => {
    mockAxiosGetError("ERR_NETWORK");
    vi.mocked(isAxiosError).mockReturnValue(true);

    await syncManager.startSync("test-token", 400, true);
    expectAxiosGetCalls(["/api/version"]);
    expectSyncSucceededPostMessage();
  });

  it("should post a metadata update", async () => {
    mockAxiosGetResolve(buildLibraryMsg());

    await syncManager.startSync("test-token", 0, true);
    expectAxiosGetCalls(["/api/library"]);
    expectSyncSucceededPostMessage();
    expect(postMessage).toHaveBeenCalledWith({
      type: LIBRARY_METADATA_TYPE,
      trackUserChanges: true,
      totalFileSize: 100,
      updateTimeNs: 200,
    } as LibraryMetadataMessage);
  });

  it("should insert tracks into the database", async () => {
    artists.set(1, new SortName({ name: "artist1" }));
    artists.set(2, new SortName({ name: "artist2", sortName: "artist2 sort" }));
    albums.set(3, new SortName({ name: "album3" }));
    genres.set(4, new Name({ name: "genre4" }));
    tracks.push(
      new Track({
        id: "id1",
        name: "name1",
        artistId: 1,
        albumArtistId: 2,
        albumId: 3,
        genreId: 4,
        year: 2000,
        duration: 300.0,
        start: 0.1,
        finish: 290.9,
        trackNumber: 0,
        discNumber: 0,
        playCount: 7,
        rating: 80,
        ext: "mp3",
        fileMd5: "md5hash1",
        artworkFilename: "",
      })
    );
    artists.set(5, new SortName({ name: "artist5" }));
    albums.set(6, new SortName({ name: "album6", sortName: "album6 sort" }));
    genres.set(7, new Name({ name: "genre7" }));
    tracks.push(
      new Track({
        id: "id2",
        name: "name2",
        artistId: 5,
        albumArtistId: 0,
        albumId: 6,
        genreId: 7,
        year: 2001,
        duration: 500.0,
        start: 0.0,
        finish: 500.0,
        trackNumber: 1,
        discNumber: 2,
        playCount: 9,
        rating: 100,
        ext: "wav",
        fileMd5: "md5hash2",
        artworkFilename: "artwork1",
      })
    );
    mockAxiosGetResolve(buildLibraryMsg());

    await syncManager.startSync("test-token", 0, true);
    expectAxiosGetCalls(["/api/library"]);
    expectSyncSucceededPostMessage();

    expect(library().putTrack).toHaveBeenCalledTimes(2);
    expect(library().putTrack).toHaveBeenCalledWith({
      id: "id1",
      name: "name1",
      sortName: "",
      artistName: "artist1",
      artistSortName: "",
      albumArtistName: "artist2",
      albumArtistSortName: "artist2 sort",
      albumName: "album3",
      albumSortName: "",
      genre: "genre4",
      year: 2000,
      duration: 300,
      start: 0.10000000149011612,
      finish: 290.8999938964844,
      trackNumber: 0,
      discNumber: 0,
      playCount: 7,
      ext: "mp3",
      fileMd5: "md5hash1",
      rating: 80,
      artwork: null,
    });
    expect(library().putTrack).toHaveBeenCalledWith({
      id: "id2",
      name: "name2",
      sortName: "",
      artistName: "artist5",
      artistSortName: "",
      albumArtistName: "",
      albumArtistSortName: "",
      albumName: "album6",
      albumSortName: "album6 sort",
      genre: "genre7",
      year: 2001,
      duration: 500,
      start: 0,
      finish: 500,
      trackNumber: 1,
      discNumber: 2,
      playCount: 9,
      ext: "wav",
      fileMd5: "md5hash2",
      rating: 100,
      artwork: "artwork1",
    });
  });

  it("should insert playlists into the database", async () => {
    /**
     * main
     * folder0
     *   playlist0_0
     *   folder0_1
     *     playlist0_1_0
     *     folder0_1_1
     *       playlist_0_1_1_0
     *       playlist_0_1_1_1
     * playlist1
     */
    playlists.push(
      new Playlist({
        id: "main",
        name: "Music",
        parentId: undefined,
        isLibrary: true,
        trackIds: ["id1", "id2"],
      })
    );
    playlists.push(
      new Playlist({
        id: "folder0",
        name: "Folder0",
        parentId: undefined,
        isLibrary: false,
        trackIds: [],
      })
    );
    playlists.push(
      new Playlist({
        id: "playlist0_0",
        name: "Playlist0_0",
        parentId: "folder0",
        isLibrary: false,
        trackIds: ["id3", "id4"],
      })
    );
    playlists.push(
      new Playlist({
        id: "folder0_1",
        name: "Folder0_1",
        parentId: "folder0",
        isLibrary: false,
        trackIds: [],
      })
    );
    playlists.push(
      new Playlist({
        id: "playlist0_1_0",
        name: "Playlist0_1_0",
        parentId: "folder0_1",
        isLibrary: false,
        trackIds: ["id5", "id6"],
      })
    );
    playlists.push(
      new Playlist({
        id: "folder0_1_1",
        name: "Folder0_1_1",
        parentId: "folder0_1",
        isLibrary: false,
        trackIds: [],
      })
    );
    playlists.push(
      new Playlist({
        id: "playlist_0_1_1_0",
        name: "Playlist_0_1_1_0",
        parentId: "folder0_1_1",
        isLibrary: false,
        trackIds: ["id7", "id8"],
      })
    );
    playlists.push(
      new Playlist({
        id: "playlist_0_1_1_1",
        name: "Playlist_0_1_1_1",
        parentId: "folder0_1_1",
        isLibrary: false,
        trackIds: ["id9", "id10"],
      })
    );
    playlists.push(
      new Playlist({
        id: "playlist1",
        name: "Playlist1",
        parentId: undefined,
        isLibrary: false,
        trackIds: ["id11", "id12"],
      })
    );
    mockAxiosGetResolve(buildLibraryMsg());

    await syncManager.startSync("test-token", 0, true);
    expectAxiosGetCalls(["/api/library"]);
    expectSyncSucceededPostMessage();

    expect(library().putPlaylist).toHaveBeenCalledTimes(9);
    expect(library().putPlaylist).toHaveBeenCalledWith({
      id: "main",
      name: "Music",
      parentId: "",
      isLibrary: true,
      trackIds: ["id1", "id2"],
      childPlaylistIds: [],
      parentPlaylistIds: [],
    });
    expect(library().putPlaylist).toHaveBeenCalledWith({
      id: "folder0",
      name: "Folder0",
      parentId: "",
      isLibrary: false,
      trackIds: [],
      childPlaylistIds: [
        "playlist0_0",
        "folder0_1",
        "playlist0_1_0",
        "folder0_1_1",
        "playlist_0_1_1_0",
        "playlist_0_1_1_1",
      ],
      parentPlaylistIds: [],
    });
    expect(library().putPlaylist).toHaveBeenCalledWith({
      id: "playlist0_0",
      name: "Playlist0_0",
      parentId: "folder0",
      isLibrary: false,
      trackIds: ["id3", "id4"],
      childPlaylistIds: [],
      parentPlaylistIds: ["folder0"],
    });
    expect(library().putPlaylist).toHaveBeenCalledWith({
      id: "folder0_1",
      name: "Folder0_1",
      parentId: "folder0",
      isLibrary: false,
      trackIds: [],
      childPlaylistIds: [
        "playlist0_1_0",
        "folder0_1_1",
        "playlist_0_1_1_0",
        "playlist_0_1_1_1",
      ],
      parentPlaylistIds: ["folder0"],
    });
    expect(library().putPlaylist).toHaveBeenCalledWith({
      id: "playlist0_1_0",
      name: "Playlist0_1_0",
      parentId: "folder0_1",
      isLibrary: false,
      trackIds: ["id5", "id6"],
      childPlaylistIds: [],
      parentPlaylistIds: ["folder0_1", "folder0"],
    });
    expect(library().putPlaylist).toHaveBeenCalledWith({
      id: "folder0_1_1",
      name: "Folder0_1_1",
      parentId: "folder0_1",
      isLibrary: false,
      trackIds: [],
      childPlaylistIds: ["playlist_0_1_1_0", "playlist_0_1_1_1"],
      parentPlaylistIds: ["folder0_1", "folder0"],
    });
    expect(library().putPlaylist).toHaveBeenCalledWith({
      id: "playlist_0_1_1_0",
      name: "Playlist_0_1_1_0",
      parentId: "folder0_1_1",
      isLibrary: false,
      trackIds: ["id7", "id8"],
      childPlaylistIds: [],
      parentPlaylistIds: ["folder0_1_1", "folder0_1", "folder0"],
    });
    expect(library().putPlaylist).toHaveBeenCalledWith({
      id: "playlist_0_1_1_1",
      name: "Playlist_0_1_1_1",
      parentId: "folder0_1_1",
      isLibrary: false,
      trackIds: ["id9", "id10"],
      childPlaylistIds: [],
      parentPlaylistIds: ["folder0_1_1", "folder0_1", "folder0"],
    });
    expect(library().putPlaylist).toHaveBeenCalledWith({
      id: "playlist1",
      name: "Playlist1",
      parentId: "",
      isLibrary: false,
      trackIds: ["id11", "id12"],
      childPlaylistIds: [],
      parentPlaylistIds: [],
    });
  });
});
