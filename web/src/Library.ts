import { memoize } from "lodash";
import { openDB, DBSchema, IDBPDatabase } from "idb";

const DATABASE_NAME = "library";
const DATABASE_VERSION = 1;

export interface Track {
  id: string;
  name: string;
  sortName: string;
  artistName: string;
  artistSortName: string;
  albumArtistName: string;
  albumArtistSortName: string;
  albumName: string;
  albumSortName: string;
  genre: string;
  year: number;
  duration: number;
  start: number;
  finish: number;
  trackNumber: number;
  discNumber: number;
  playCount: number;
  rating: number;
  ext: string;
  artworks: string[];
}

export interface Playlist {
  id: string;
  name: string;
  parentId: string;
  isLibrary: boolean;
  trackIds: string[];
}

interface LibraryDB extends DBSchema {
  tracks: {
    key: string;
    value: Track;
  };
  playlists: {
    key: string;
    value: Playlist;
  };
}

class Library {
  private db?: IDBPDatabase<LibraryDB>;
  private validState: boolean = true;
  private lastError: string = "";
  private errorListener?: (error: string) => void = undefined;

  public constructor() {
    const setError = this.setError.bind(this);
    openDB<LibraryDB>(DATABASE_NAME, DATABASE_VERSION, {
      upgrade(db) {
        db.createObjectStore("tracks", { keyPath: "id" });
        db.createObjectStore("playlists", { keyPath: "id" });
      },
      blocked(currentVersion, blockedVersion) {
        setError(
          "using database",
          `version ${currentVersion} is blocked by version ${blockedVersion}`
        );
      },
      blocking(currentVersion, blockedVersion) {
        setError(
          "using database",
          `version ${currentVersion} is blocking version ${blockedVersion}`
        );
      },
      terminated() {
        setError("using database", "connection terminated");
      },
    })
      .then((db) => {
        this.db = db;
      })
      .catch((error) => {
        this.setError("opening database", error);
      });

    // navigator.storage.persist().then((granted) => {
    //   console.log("persistent storage granted:", granted);
    // });
  }

  public setErrorListener(listener: (error: string) => void) {
    this.errorListener = listener;
    if (!this.inValidState()) {
      listener(this.lastError);
    }
  }

  public inValidState() {
    return this.validState;
  }

  public getLastError() {
    return this.lastError;
  }

  public async hasAny() {
    if (!this.validState) {
      return false;
    }
    if (!this.db) {
      this.setError("checking store", "database is not initialized");
      return false;
    }

    try {
      const trackCount = await this.db.count("tracks");
      const playlistCount = await this.db.count("playlists");
      return trackCount > 0 && playlistCount > 0;
    } catch (error) {
      this.setError("checking store", error);
      return false;
    }
  }

  public async putTrack(track: Track) {
    if (!this.validState) {
      return false;
    }
    if (!this.db) {
      this.setError("put item", "database is not initialized");
      return false;
    }

    try {
      await this.db.put("tracks", track);
    } catch (error) {
      this.setError("put track", error);
    }
  }

  public async putPlaylist(playlist: Playlist) {
    if (!this.validState) {
      return false;
    }
    if (!this.db) {
      this.setError("put playlist", "database is not initialized");
      return false;
    }

    try {
      await this.db.put("playlists", playlist);
    } catch (error) {
      this.setError("put playlist", error);
    }
  }

  public clear() {
    if (!this.validState) {
      return;
    }
    if (!this.db) {
      this.setError("clearing store", "database is not initialized");
      return;
    }

    try {
      this.db.clear("tracks");
      this.db.clear("playlists");
    } catch (error) {
      this.setError("clearing store", error);
    }
  }

  public async getAllPlaylists(): Promise<Playlist[] | undefined> {
    if (!this.validState) {
      return;
    }
    if (!this.db) {
      this.setError("getting playlists", "database is not initialized");
      return;
    }

    const tx = this.db.transaction("playlists", "readonly");
    const store = tx.objectStore("playlists");
    return await store.getAll();
  }

  public async getAllPlaylistTracks(
    playlistId: string
  ): Promise<Track[] | undefined> {
    if (!this.validState) {
      return;
    }
    if (!this.db) {
      this.setError("getting playlist tracks", "database is not initialized");
      return;
    }

    const playlistTx = this.db.transaction("playlists", "readonly");
    const playlistStore = playlistTx.objectStore("playlists");
    const playlist = await playlistStore.get(playlistId);
    if (!playlist) {
      return [];
    }

    const trackTx = this.db.transaction("tracks", "readonly");
    const trackStore = trackTx.objectStore("tracks");
    if (playlist.isLibrary) {
      return trackStore.getAll();
    } else {
      const tracks = await Promise.all(
        playlist.trackIds.map((trackId) => trackStore.get(trackId))
      );
      return tracks.filter((track): track is Track => track !== undefined);
    }
  }

  public async getTrackIds(): Promise<Set<string> | undefined> {
    if (!this.validState) {
      return;
    }
    if (!this.db) {
      this.setError("getting track ids", "database is not initialized");
      return;
    }

    const tx = this.db.transaction("tracks", "readonly");
    const store = tx.objectStore("tracks");
    return new Set(await store.getAllKeys());
  }

  public async getArtworkIds(): Promise<Set<string> | undefined> {
    if (!this.validState) {
      return;
    }
    if (!this.db) {
      this.setError("getting track ids", "database is not initialized");
      return;
    }

    const tx = this.db.transaction("tracks", "readonly");
    const store = tx.objectStore("tracks");
    const tracks = await store.getAll();
    return new Set(
      tracks.filter((t) => t.artworks.length > 0).flatMap((t) => t.artworks)
    );
  }

  public async getTrack(trackId: string): Promise<Track | undefined> {
    if (!this.validState) {
      return;
    }
    if (!this.db) {
      this.setError("getting track", "database is not initialized");
      return;
    }

    const tx = this.db.transaction("tracks", "readonly");
    const store = tx.objectStore("tracks");
    return await store.get(trackId);
  }

  private setError(action: string, error: Error | string | null | unknown) {
    this.validState = false;

    this.lastError = `error while ${action}: `;
    if (error instanceof Error) {
      this.lastError += error.message;
    } else if (error) {
      this.lastError += error;
    } else {
      this.lastError += "unknown error";
    }
    console.error(this.validState, error);
    if (this.errorListener) {
      this.errorListener(this.lastError);
    }
  }
}

const library = memoize(() => new Library());
library();
export default library;
