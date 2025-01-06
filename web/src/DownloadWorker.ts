import axios from "axios";
import {
  isTypedMessage,
  isSetAuthTokenMessage,
  isFetchTrackMessage,
  isFetchArtworkMessage,
  isClearedAllMessage,
  TRACK_FETCHED_TYPE,
  ARTWORK_FETCHED_TYPE,
} from "./WorkerTypes";
import { files } from "./Files";

class DownloadManager {
  private authToken: string = "";
  private inflightRequests = new Set<string>();

  public constructor() {
    // NB: purposefully don't initialize the Files instance here, could be race condition-y?
  }

  public setAuthToken(authToken: string) {
    this.authToken = authToken;
  }

  public async fetchTrack(trackId: string, attemptsLeft = 3) {
    if (!files().tracksInitialized()) {
      if (attemptsLeft <= 0) {
        console.error(
          "trackDirHandle is not initialized and still isn't after 3 attempts, giving up"
        );
        return;
      }
      setTimeout(() => this.fetchTrack(trackId, attemptsLeft - 1), 100);
      return;
    }

    await this.fetchFile(
      trackId,
      TRACK_FETCHED_TYPE,
      "tracks",
      "trackId",
      files().trackExists.bind(files()),
      files().tryWriteTrack.bind(files())
    );
  }

  public async fetchArtwork(artworkId: string, attemptsLeft = 3) {
    if (!files().artworkInitialized()) {
      if (attemptsLeft <= 0) {
        console.error(
          "artworkDirHandle is not initialized and still isn't after 3 attempts, giving up"
        );
        return;
      }
      setTimeout(() => this.fetchArtwork(artworkId, attemptsLeft - 1), 100);
      return;
    }

    await this.fetchFile(
      artworkId,
      ARTWORK_FETCHED_TYPE,
      "artwork",
      "artworkId",
      files().artworkExists.bind(files()),
      files().tryWriteArtwork.bind(files())
    );
  }

  private async fetchFile(
    id: string,
    fetchedType: string,
    urlPrefix: string,
    msgKey: string,
    existsFn: (id: string) => Promise<boolean>,
    writeFn: (id: string, data: FileSystemWriteChunkType) => Promise<boolean>
  ) {
    if (this.inflightRequests.has(id)) {
      return;
    }
    this.inflightRequests.add(id);

    if (await existsFn(id)) {
      postMessage({ type: fetchedType, [msgKey]: id });
      this.inflightRequests.delete(id);
      return;
    }

    // TODO retry logic?
    try {
      const requestPath = `/${urlPrefix}/${id}`;
      const { data } = await axios.get(requestPath, {
        responseType: "arraybuffer",
        headers: { Authorization: `Bearer ${this.authToken}` },
      });
      if (await writeFn(id, data)) {
        postMessage({ type: fetchedType, [msgKey]: id });
      }
    } catch (error) {
      console.error(error);
    } finally {
      this.inflightRequests.delete(id);
    }
  }

  public async clearedAll() {
    files().reset();
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
    downloadManager.fetchTrack(data.trackId);
  }

  if (isFetchArtworkMessage(data)) {
    downloadManager.fetchArtwork(data.artworkId);
  }

  if (isClearedAllMessage(data)) {
    downloadManager.clearedAll();
  }
};
