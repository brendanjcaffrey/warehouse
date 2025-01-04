import axios from "axios";
import {
  isTypedMessage,
  isSetAuthTokenMessage,
  isFetchTrackMessage,
  isFetchArtworkMessage,
  isClearAllMessage,
  TRACK_FETCHED_TYPE,
  ARTWORK_FETCHED_TYPE,
} from "./WorkerTypes";

class DownloadManager {
  private authToken: string = "";
  private inflightRequests = new Set<string>();
  private trackDirHandle: FileSystemDirectoryHandle | undefined = undefined;
  private artworkDirHandle: FileSystemDirectoryHandle | undefined = undefined;

  public constructor() {
    this.getTrackDirHandle();
    this.getArtworkDirHandle();
  }

  private async getTrackDirHandle() {
    const mainDirHandle = await navigator.storage.getDirectory();
    const trackDirHandle = await mainDirHandle.getDirectoryHandle("track", {
      create: true,
    });
    this.trackDirHandle = trackDirHandle;
  }

  private async getArtworkDirHandle() {
    const mainDirHandle = await navigator.storage.getDirectory();
    const artworkDirHandle = await mainDirHandle.getDirectoryHandle("artwork", {
      create: true,
    });
    this.artworkDirHandle = artworkDirHandle;
  }

  public setAuthToken(authToken: string) {
    this.authToken = authToken;
  }

  public async fetchTrack(trackFilename: string, attemptsLeft = 3) {
    if (!this.trackDirHandle) {
      if (attemptsLeft <= 0) {
        console.error(
          "trackDirHandle is not initialized and still isn't after 3 attempts, giving up"
        );
        return;
      }
      setTimeout(() => this.fetchTrack(trackFilename, attemptsLeft - 1), 100);
      return;
    }
    await this.fetchFile(
      this.trackDirHandle,
      trackFilename,
      TRACK_FETCHED_TYPE,
      "tracks",
      "trackFilename"
    );
  }

  public async fetchArtwork(artworkFilename: string, attemptsLeft = 3) {
    if (!this.artworkDirHandle) {
      if (attemptsLeft <= 0) {
        console.error(
          "artworkDirHandle is not initialized and still isn't after 3 attempts, giving up"
        );
        return;
      }
      setTimeout(
        () => this.fetchArtwork(artworkFilename, attemptsLeft - 1),
        100
      );
      return;
    }

    this.fetchFile(
      this.artworkDirHandle,
      artworkFilename,
      ARTWORK_FETCHED_TYPE,
      "artwork",
      "artworkFilename"
    );
  }

  private async fetchFile(
    dirHandle: FileSystemDirectoryHandle,
    filename: string,
    fetchedType: string,
    urlPrefix: string,
    msgKey: string
  ) {
    if (this.inflightRequests.has(filename)) {
      console.log(`Request for ${filename} is already inflight`);
      return;
    }
    this.inflightRequests.add(filename);

    try {
      await dirHandle?.getFileHandle(filename);
      console.log(`Already have ${filename}`);
      postMessage({ type: fetchedType, [msgKey]: filename });
      this.inflightRequests.delete(filename);
      return;
    } catch (error) {
      if (error instanceof DOMException && error.name === "NotFoundError") {
        // nop
      } else {
        console.error(error);
      }
    }

    try {
      const requestPath = `/${urlPrefix}/${filename}`;
      console.log(`Fetching ${requestPath} with ${this.authToken}`);
      const { data } = await axios.get(requestPath, {
        responseType: "arraybuffer",
        headers: { Authorization: `Bearer ${this.authToken}` },
      });
      const fileHandle = await dirHandle?.getFileHandle(filename, {
        create: true,
      });
      const writable = await fileHandle.createWritable();
      writable.write(data);
      writable.close();
      postMessage({ type: fetchedType, [msgKey]: filename });
    } catch (error) {
      console.error(error);
    } finally {
      this.inflightRequests.delete(filename);
    }
  }

  public async clearAll() {
    try {
      const mainDirHandle = await navigator.storage.getDirectory();
      mainDirHandle.removeEntry("tracks", { recursive: true });
      this.trackDirHandle = undefined;
      this.getTrackDirHandle();

      mainDirHandle.removeEntry("artwork", { recursive: true });
      this.artworkDirHandle = undefined;
      this.getArtworkDirHandle();
      console.log("All files and directories have been deleted.");
    } catch (error) {
      console.error("Error deleting files:", error);
    }
  }
}

const downloadManager = new DownloadManager();

onmessage = (m: MessageEvent) => {
  const { data } = m;
  if (!isTypedMessage(data)) {
    return;
  }

  if (isSetAuthTokenMessage(data)) {
    downloadManager.setAuthToken(data.authToken);
  }

  if (isFetchTrackMessage(data)) {
    downloadManager.fetchTrack(data.trackFilename);
  }

  if (isFetchArtworkMessage(data)) {
    downloadManager.fetchArtwork(data.artworkFilename);
  }

  if (isClearAllMessage(data)) {
    downloadManager.clearAll();
  }
};
