import axios from "axios";
import {
  isTypedMessage,
  isSetAuthTokenMessage,
  isFetchArtworkMessage,
  isClearAllMessage,
  ARTWORK_FETCHED_TYPE,
} from "./WorkerTypes";

class ArtworkManager {
  private authToken: string = "";
  private inflightRequests = new Set<string>();
  private artworkDirHandle: FileSystemDirectoryHandle | undefined = undefined;

  public constructor() {
    this.getArtworkDirHandle();
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

  public async fetchArtwork(artworkFilename: string, attemptsLeft = 3) {
    if (!this.artworkDirHandle) {
      if (attemptsLeft <= 0) {
        console.log(
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

    if (this.inflightRequests.has(artworkFilename)) {
      return;
    }
    this.inflightRequests.add(artworkFilename);

    try {
      await this.artworkDirHandle?.getFileHandle(artworkFilename);
      postMessage({ type: ARTWORK_FETCHED_TYPE, artworkFilename });
      this.inflightRequests.delete(artworkFilename);
      return;
    } catch (error) {
      if (error instanceof DOMException && error.name === "NotFoundError") {
        // nop
      } else {
        console.error(error);
      }
    }

    try {
      const { data } = await axios.get(`/artwork/${artworkFilename}`, {
        responseType: "arraybuffer",
        headers: { Authorization: `Bearer ${this.authToken}` },
      });
      const fileHandle = await this.artworkDirHandle?.getFileHandle(
        artworkFilename,
        { create: true }
      );
      const writable = await fileHandle.createWritable();
      writable.write(data);
      writable.close();
      postMessage({ type: ARTWORK_FETCHED_TYPE, artworkFilename });
    } catch (error) {
      console.error(error);
    } finally {
      this.inflightRequests.delete(artworkFilename);
    }
  }

  public async clearAll() {
    try {
      const mainDirHandle = await navigator.storage.getDirectory();
      mainDirHandle.removeEntry("artwork", { recursive: true });
      this.artworkDirHandle = undefined;
      this.getArtworkDirHandle();
      console.log("All files and directories have been deleted.");
    } catch (error) {
      console.error("Error deleting files:", error);
    }
  }
}

const artworkManager = new ArtworkManager();

onmessage = (m: MessageEvent) => {
  const { data } = m;
  if (!isTypedMessage(data)) {
    return;
  }

  if (isSetAuthTokenMessage(data)) {
    artworkManager.setAuthToken(data.authToken);
  }

  if (isFetchArtworkMessage(data)) {
    artworkManager.fetchArtwork(data.artworkFilename);
  }

  if (isClearAllMessage(data)) {
    artworkManager.clearAll();
  }
};
