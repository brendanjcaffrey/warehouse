import { Mutex } from "async-mutex";
import axios from "axios";
import {
  FileType,
  FileRequestSource,
  IsTypedMessage,
  IsSetAuthTokenMessage,
  IsKeepModeChangedMessage,
  IsClearedAllMessage,
  IsSetSourceRequestedFilesMessage,
  SetSourceRequestedFilesMessage,
  IsSyncSucceededMessage,
  FILE_FETCHED_TYPE,
} from "./WorkerTypes";
import { files } from "./Files";
import library from "./Library";

interface RequestedFile {
  type: FileType;
  id: string;
}

function RequestedFileToString(file: RequestedFile) {
  return `${file.type}/${file.id}`;
}

class InFlightRequest {
  type: FileType;
  id: string;
  canceled: boolean;
  abortController: AbortController;

  constructor(type: FileType, id: string) {
    this.type = type;
    this.id = id;
    this.canceled = false;
    this.abortController = new AbortController();
  }

  abort() {
    this.canceled = true;
    this.abortController.abort();
  }
}

export class DownloadManager {
  private mutex = new Mutex();
  private authToken: string = "";
  private keepMode: boolean = true;
  private sources = new Map<FileRequestSource, RequestedFile[]>();
  private inflightRequests: InFlightRequest[] = [];
  private lastFailedRequest = new Map<FileType, string>();

  public constructor() {
    // NB: purposefully don't initialize the Files instance here, could be race condition-y?
  }

  public async syncSucceeded() {
    const trackIds = await library().getTrackIds();
    if (trackIds) {
      await this.removeTrackFilesExcept(trackIds);
    }
    const artworkIds = await library().getArtworkIds();
    if (artworkIds) {
      await this.removeArtworkFilesExcept(artworkIds);
    }
  }

  public setAuthToken(authToken: string) {
    this.authToken = authToken;
  }

  public async setKeepMode(keepMode: boolean) {
    if (this.keepMode === keepMode) {
      return;
    }

    this.keepMode = keepMode;
    await this.update();
  }

  public async setSourceRequestedFiles(data: SetSourceRequestedFilesMessage) {
    this.sources.set(
      data.source,
      data.ids.map((id) => ({ type: data.fileType, id }))
    );
    await this.update();
  }

  public update(): Promise<void> {
    return this.mutex.runExclusive(async () => await this.updateExclusive());
  }

  private async updateExclusive() {
    console.assert(this.mutex.isLocked());

    if (
      !this.authToken ||
      !files().typeIsInitialized(FileType.TRACK) ||
      !files().typeIsInitialized(FileType.ARTWORK)
    ) {
      setTimeout(async () => await this.update(), 100);
      return;
    }

    if (!this.keepMode) {
      this.cancelUnneededRequests();
    }
    await this.startNewRequests();
    await this.deleteUnneededFiles();
  }

  private async startNewRequests() {
    for (const requestedFiles of this.sources.values()) {
      for (const file of requestedFiles) {
        if (await files().fileExists(file.type, file.id)) {
          continue;
        }
        if (this.hasMatchingInFlightRequest(file)) {
          break;
        }
        this.fetchFile(file);
        break;
      }
    }
  }

  private hasMatchingInFlightRequest(request: RequestedFile) {
    return this.inflightRequests.some(
      (r) => r.type === request.type && r.id === request.id
    );
  }

  private cancelUnneededRequests() {
    const allInFlightRequests = new Set<string>();
    for (const source of this.sources.values()) {
      for (const file of source) {
        allInFlightRequests.add(RequestedFileToString(file));
      }
    }
    for (const request of this.inflightRequests) {
      const requestStr = RequestedFileToString(request);
      if (!allInFlightRequests.has(requestStr)) {
        request.abort();
      }
    }
    this.inflightRequests = this.inflightRequests.filter((r) => !r.canceled);
  }

  private async fetchFile(request: RequestedFile) {
    if (this.lastFailedRequest.get(request.type) === request.id) {
      setTimeout(() => {
        if (this.lastFailedRequest.get(request.type) === request.id) {
          this.lastFailedRequest.delete(request.type);
        }
        this.update();
      }, 5000);
      return;
    }

    const inflightRequest = new InFlightRequest(request.type, request.id);
    this.inflightRequests.push(inflightRequest);

    try {
      const urlPrefix = request.type === FileType.TRACK ? "tracks" : "artwork";
      const requestPath = `/${urlPrefix}/${request.id}`;
      const { data } = await axios.get(requestPath, {
        signal: inflightRequest.abortController.signal,
        responseType: "arraybuffer",
        headers: { Authorization: `Bearer ${this.authToken}` },
      });
      if (await files().tryWriteFile(request.type, request.id, data)) {
        postMessage({
          type: FILE_FETCHED_TYPE,
          fileType: request.type,
          id: request.id,
        });
      }
    } catch (error) {
      if (!inflightRequest.canceled) {
        console.error(error);
        this.lastFailedRequest.set(request.type, request.id);
      }
    } finally {
      this.inflightRequests = this.inflightRequests.filter(
        (r) => r !== inflightRequest
      );
      this.update();
    }
  }

  private async deleteUnneededFiles() {
    if (this.keepMode) {
      return;
    }
    const trackIds = new Set<string>();
    const artworkIds = new Set<string>();
    for (const requestedFiles of this.sources.values()) {
      for (const file of requestedFiles) {
        if (file.type === FileType.TRACK) {
          trackIds.add(file.id);
        } else {
          artworkIds.add(file.id);
        }
      }
    }
    this.removeTrackFilesExcept(trackIds);
    this.removeArtworkFilesExcept(artworkIds);
  }

  private async removeTrackFilesExcept(trackIds: Set<string>) {
    const trackFiles = await files().getAllOfType(FileType.TRACK);
    if (!trackFiles) {
      return;
    }

    const tracksToDelete = new Set(
      [...trackFiles].filter((x) => !trackIds.has(x))
    );
    for (const file of tracksToDelete) {
      await files().tryDeleteFile(FileType.TRACK, file);
    }
  }

  private async removeArtworkFilesExcept(artworkIds: Set<string>) {
    const artworkFiles = await files().getAllOfType(FileType.ARTWORK);
    if (!artworkFiles) {
      return;
    }

    const artworkToDelete = new Set(
      [...artworkFiles].filter((x) => !artworkIds.has(x))
    );
    for (const file of artworkToDelete) {
      await files().tryDeleteFile(FileType.ARTWORK, file);
    }
  }

  public async clearedAll() {
    files().reset();
  }
}

const downloadManager = new DownloadManager();

onmessage = (m: MessageEvent) => {
  const { data } = m;
  if (!IsTypedMessage(data)) {
    return;
  }

  if (IsSetAuthTokenMessage(data)) {
    downloadManager.setAuthToken(data.authToken);
  }

  if (IsSyncSucceededMessage(data)) {
    downloadManager.syncSucceeded();
  }

  if (IsKeepModeChangedMessage(data)) {
    downloadManager.setKeepMode(data.keepMode);
  }

  if (IsSetSourceRequestedFilesMessage(data)) {
    downloadManager.setSourceRequestedFiles(data);
  }

  if (IsClearedAllMessage(data)) {
    downloadManager.clearedAll();
  }
};
