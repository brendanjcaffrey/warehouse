import { Mutex } from "async-mutex";
import axios from "axios";
import {
  FileType,
  FileRequestSource,
  IsTypedMessage,
  IsSetAuthTokenMessage,
  IsKeepModeChangedMessage,
  IsDownloadModeChangedMessage,
  IsClearedAllMessage,
  IsSetSourceRequestedFilesMessage,
  SetSourceRequestedFilesMessage,
  IsSyncSucceededMessage,
  TrackFileIds,
  FileFetchedMessage,
  FileDownloadStatusMessage,
  DownloadStatus,
  FILE_FETCHED_TYPE,
  FILE_DOWNLOAD_STATUS_TYPE,
} from "./WorkerTypes";
import { files } from "./Files";
import library from "./Library";

interface RequestedFile {
  type: FileType;
  ids: TrackFileIds;
}

function RequestedFileToString(file: RequestedFile) {
  return `${file.type}/${file.ids.fileId}`;
}

class InFlightRequest {
  type: FileType;
  ids: TrackFileIds;
  canceled: boolean;
  abortController: AbortController;

  constructor(type: FileType, ids: TrackFileIds) {
    this.type = type;
    this.ids = ids;
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
  private libraryInitialized: boolean = false;
  private authToken: string = "";
  // safest to initialize to true, since we don't want to delete files at startup
  private keepMode: boolean = true;
  // safest to initialize to false, since we don't want to download everything unnessarily
  private downloadMode: boolean = false;
  private sources = new Map<FileRequestSource, RequestedFile[]>();
  private inflightRequests: InFlightRequest[] = [];
  private lastFailedRequest = new Map<FileType, string>();
  private missingMusicFiles = new Array<TrackFileIds>();
  private missingArtworkFiles = new Array<TrackFileIds>();

  public constructor() {
    // NB: purposefully don't initialize the Files instance here, could be race condition-y?
    library().setInitializedListener(async () => {
      this.libraryInitialized = true;
      if (this.downloadMode) {
        await this.gatherMissingFiles();
      }
    });
  }

  public async syncSucceeded() {
    const musicIds = await library().getMusicIds();
    if (musicIds) {
      await this.removeMusicFilesExcept(musicIds);
    }
    const artworkIds = await library().getArtworkIds();
    if (artworkIds) {
      await this.removeArtworkFilesExcept(artworkIds);
    }
    if (this.downloadMode && this.libraryInitialized) {
      await this.gatherMissingFiles();
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

  public async setDownloadMode(downloadMode: boolean) {
    if (this.downloadMode === downloadMode) {
      return;
    }

    this.downloadMode = downloadMode;
    if (!this.downloadMode) {
      this.missingMusicFiles = [];
      this.sources.set(FileRequestSource.DOWNLOAD_MODE_MUSIC, []);

      this.missingArtworkFiles = [];
      this.sources.set(FileRequestSource.DOWNLOAD_MODE_ARTWORK, []);
    } else if (this.libraryInitialized) {
      await this.gatherMissingFiles();
    }
    await this.update();
  }

  public async setSourceRequestedFiles(data: SetSourceRequestedFilesMessage) {
    this.sources.set(
      data.source,
      data.ids.map((ids) => ({ type: data.fileType, ids }))
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
      !files().typeIsInitialized(FileType.MUSIC) ||
      !files().typeIsInitialized(FileType.ARTWORK)
    ) {
      setTimeout(async () => await this.update(), 100);
      return;
    }

    if (!this.keepMode) {
      this.cancelUnneededRequests();
    }
    const startedRequest = await this.startNewRequests();
    await this.deleteUnneededFiles();

    if (
      !startedRequest &&
      this.libraryInitialized &&
      this.downloadMode &&
      this.inflightRequests.length === 0
    ) {
      await this.setDownloadModeRequestedFiles();
      await this.startNewRequests();
    }
  }

  private async startNewRequests(): Promise<boolean> {
    let startedAny = false;
    for (const requestedFiles of this.sources.values()) {
      for (const file of requestedFiles) {
        if (await files().fileExists(file.type, file.ids.fileId)) {
          continue;
        }
        if (this.hasMatchingInFlightRequest(file)) {
          break;
        }
        /* not awaiting */ this.fetchFile(file);
        startedAny = true;
        break;
      }
    }
    return startedAny;
  }

  private async setDownloadModeRequestedFiles() {
    const musicRequestedFiles: RequestedFile[] = [];
    if (this.missingMusicFiles.length > 0) {
      musicRequestedFiles.push({
        type: FileType.MUSIC,
        ids: this.missingMusicFiles[0],
      });
    }
    this.sources.set(
      FileRequestSource.DOWNLOAD_MODE_MUSIC,
      musicRequestedFiles
    );

    const artworkRequestedFiles: RequestedFile[] = [];
    if (
      this.missingMusicFiles.length === 0 &&
      this.missingArtworkFiles.length > 0
    ) {
      artworkRequestedFiles.push({
        type: FileType.ARTWORK,
        ids: this.missingArtworkFiles[0],
      });
    }
    this.sources.set(
      FileRequestSource.DOWNLOAD_MODE_ARTWORK,
      artworkRequestedFiles
    );
  }

  private hasMatchingInFlightRequest(request: RequestedFile) {
    return this.inflightRequests.some(
      (r) =>
        r.type === request.type &&
        r.ids.trackId === request.ids.trackId &&
        r.ids.fileId === request.ids.fileId
    );
  }

  private cancelUnneededRequests() {
    const allRequestedFiles = new Set<string>();
    for (const source of this.sources.values()) {
      for (const file of source) {
        allRequestedFiles.add(RequestedFileToString(file));
      }
    }
    for (const request of this.inflightRequests) {
      const requestStr = RequestedFileToString(request);
      if (!allRequestedFiles.has(requestStr)) {
        request.abort();
        this.postStatus(request, DownloadStatus.CANCELED);
      }
    }
    this.inflightRequests = this.inflightRequests.filter((r) => !r.canceled);
  }

  private async postStatus(
    request: RequestedFile,
    status: DownloadStatus,
    receivedBytes = 0,
    totalBytes = 0
  ) {
    postMessage({
      type: FILE_DOWNLOAD_STATUS_TYPE,
      ids: request.ids,
      fileType: request.type,
      status: status,
      receivedBytes: receivedBytes,
      totalBytes: totalBytes,
    } as FileDownloadStatusMessage);
  }

  private async fetchFile(request: RequestedFile) {
    if (this.lastFailedRequest.get(request.type) === request.ids.fileId) {
      setTimeout(() => {
        if (this.lastFailedRequest.get(request.type) === request.ids.fileId) {
          this.lastFailedRequest.delete(request.type);
        }
        this.update();
      }, 5000);
      return;
    }

    const inflightRequest = new InFlightRequest(request.type, request.ids);
    this.inflightRequests.push(inflightRequest);
    this.postStatus(request, DownloadStatus.IN_PROGRESS);

    try {
      const urlPrefix = request.type === FileType.MUSIC ? "music" : "artwork";
      const requestPath = `/${urlPrefix}/${request.ids.fileId}`;
      const { data } = await axios.get(requestPath, {
        signal: inflightRequest.abortController.signal,
        responseType: "arraybuffer",
        headers: { Authorization: `Bearer ${this.authToken}` },
        onDownloadProgress: (e) => {
          this.postStatus(
            request,
            DownloadStatus.IN_PROGRESS,
            e.loaded,
            e.total
          );
        },
      });
      if (await files().tryWriteFile(request.type, request.ids.fileId, data)) {
        postMessage({
          type: FILE_FETCHED_TYPE,
          fileType: request.type,
          ids: request.ids,
        } as FileFetchedMessage);
        this.postStatus(
          request,
          DownloadStatus.DONE,
          data.byteLength,
          data.byteLength
        );
        if (request.type === FileType.MUSIC) {
          this.missingMusicFiles = this.missingMusicFiles.filter(
            (tfi) => tfi.fileId !== request.ids.fileId
          );
        } else {
          this.missingArtworkFiles = this.missingArtworkFiles.filter(
            (tfi) => tfi.fileId !== request.ids.fileId
          );
        }
      }
    } catch (error) {
      if (!inflightRequest.canceled) {
        console.error(error);
        this.lastFailedRequest.set(request.type, request.ids.fileId);
        this.postStatus(request, DownloadStatus.ERROR);
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
    const musicIds = new Set<string>();
    const artworkIds = new Set<string>();
    for (const requestedFiles of this.sources.values()) {
      for (const file of requestedFiles) {
        if (file.type === FileType.MUSIC) {
          musicIds.add(file.ids.fileId);
        } else {
          artworkIds.add(file.ids.fileId);
        }
      }
    }
    this.removeMusicFilesExcept(musicIds);
    this.removeArtworkFilesExcept(artworkIds);
  }

  private async removeMusicFilesExcept(musicIds: Set<string>) {
    const musicFiles = await files().getAllOfType(FileType.MUSIC);
    if (!musicFiles) {
      return;
    }

    const tracksToDelete = new Set(
      [...musicFiles].filter((x) => !musicIds.has(x))
    );
    for (const file of tracksToDelete) {
      await files().tryDeleteFile(FileType.MUSIC, file);
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

  private async gatherMissingFiles() {
    this.missingMusicFiles = [];
    this.missingArtworkFiles = [];

    const trackMusicIds = await library().getTrackMusicIds();
    for (const trackMusicId of trackMusicIds!.values()) {
      if (!(await files().fileExists(FileType.MUSIC, trackMusicId.fileId))) {
        this.missingMusicFiles.push(trackMusicId);
      }
    }

    const trackArtworkIds = await library().getTrackArtworkIds();
    for (const trackArtworkId of trackArtworkIds!.values()) {
      if (
        !(await files().fileExists(FileType.ARTWORK, trackArtworkId.fileId))
      ) {
        this.missingArtworkFiles.push(trackArtworkId);
      }
    }

    await this.update();
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

  if (IsDownloadModeChangedMessage(data)) {
    downloadManager.setDownloadMode(data.downloadMode);
  }

  if (IsSetSourceRequestedFilesMessage(data)) {
    downloadManager.setSourceRequestedFiles(data);
  }

  if (IsClearedAllMessage(data)) {
    downloadManager.clearedAll();
  }
};
