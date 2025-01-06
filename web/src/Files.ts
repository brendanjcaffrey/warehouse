import { memoize } from "lodash";

class Files {
  artworkDirHandle: FileSystemDirectoryHandle | null = null;
  trackDirHandle: FileSystemDirectoryHandle | null = null;

  constructor() {
    this.reset();
  }

  reset() {
    this.trackDirHandle = null;
    this.artworkDirHandle = null;
    this.getTrackDirHandle();
    this.getArtworkDirHandle();
  }

  async clearAll() {
    const mainDirHandle = await navigator.storage.getDirectory();
    await mainDirHandle.removeEntry("tracks", { recursive: true });
    await mainDirHandle.removeEntry("artwork", { recursive: true });
    this.reset();
  }

  artworkInitialized() {
    return this.artworkDirHandle !== null;
  }

  tracksInitialized() {
    return this.trackDirHandle !== null;
  }

  async getArtworkDirHandle() {
    try {
      const mainDir = await navigator.storage.getDirectory();
      const artworkDirHandle = await mainDir.getDirectoryHandle("artwork", {
        create: true,
      });
      this.artworkDirHandle = artworkDirHandle;
    } catch (e) {
      console.error("unable to get artwork dir handle", e);
    }
  }

  async getTrackDirHandle() {
    try {
      const mainDir = await navigator.storage.getDirectory();
      const trackDirHandle = await mainDir.getDirectoryHandle("tracks", {
        create: true,
      });
      this.trackDirHandle = trackDirHandle;
    } catch (e) {
      console.error("unable to get track dir handle", e);
    }
  }

  async artworkExists(artworkId: string): Promise<boolean> {
    try {
      await this.artworkDirHandle!.getFileHandle(artworkId);
      return true;
    } catch {
      return false;
    }
  }

  async trackExists(trackId: string): Promise<boolean> {
    try {
      await this.trackDirHandle!.getFileHandle(trackId);
      return true;
    } catch {
      return false;
    }
  }

  async tryGetArtworkURL(artworkId: string): Promise<string | null> {
    try {
      const fileHandle = await this.artworkDirHandle!.getFileHandle(artworkId);
      const file = await fileHandle.getFile();
      return URL.createObjectURL(file);
    } catch {
      return null;
    }
  }

  async tryGetTrackURL(trackId: string): Promise<string | null> {
    try {
      const fileHandle = await this.trackDirHandle!.getFileHandle(trackId);
      const file = await fileHandle.getFile();
      return URL.createObjectURL(file);
    } catch {
      return null;
    }
  }

  async tryWriteArtwork(
    artworkId: string,
    data: FileSystemWriteChunkType
  ): Promise<boolean> {
    try {
      const fileHandle = await this.artworkDirHandle!.getFileHandle(artworkId, {
        create: true,
      });
      const writable = await fileHandle.createWritable();
      await writable.write(data);
      await writable.close();
      return true;
    } catch (e) {
      console.error(e);
      return false;
    }
  }

  async tryWriteTrack(
    trackId: string,
    data: FileSystemWriteChunkType
  ): Promise<boolean> {
    try {
      const fileHandle = await this.trackDirHandle!.getFileHandle(trackId, {
        create: true,
      });
      const writable = await fileHandle.createWritable();
      await writable.write(data);
      await writable.close();
      return true;
    } catch {
      return false;
    }
  }
}

export const files = memoize(() => new Files());
