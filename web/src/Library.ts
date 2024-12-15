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
