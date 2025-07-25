import { Mutex } from "async-mutex";
import { LRUCache } from "typescript-lru-cache";
import { memoize } from "lodash";
import library from "./Library";
import {
  FileDownloadStatusMessage,
  TrackFileIds,
  FileType,
  DownloadStatus,
} from "./WorkerTypes";
import { store, anyDownloadErrorsAtom } from "./State";

const DEFAULT_MAX_SIZE = 100;

export interface Download {
  ids: TrackFileIds;
  fileType: FileType;
  status: DownloadStatus;
  receivedBytes: number;
  totalBytes: number;
  trackDesc: string;
  lastUpdate: number;
}

export class DownloadsStore {
  private mutex = new Mutex();
  private cache = new LRUCache<string, string>();
  private downloads: Download[] = [];
  private maxSize: number;

  constructor(maxSize: number = DEFAULT_MAX_SIZE) {
    this.maxSize = maxSize;
  }

  async update(newStatus: FileDownloadStatusMessage) {
    await this.mutex.runExclusive(async () => this.updateExclusive(newStatus));
  }

  async updateExclusive(newStatus: FileDownloadStatusMessage) {
    const trackDescKey = `${newStatus.ids.trackId}-${newStatus.ids.fileId}`;
    let trackDesc = this.cache.get(trackDescKey);
    if (!trackDesc) {
      const track = await library().getTrack(newStatus.ids.trackId);
      if (!track) {
        return;
      }

      trackDesc = `${track.name} - ${track.artistName}`;
      this.cache.set(trackDescKey, trackDesc);
    }

    // remove any existing entry with the same ids
    this.downloads = this.downloads.filter(
      (d) =>
        d.ids.trackId !== newStatus.ids.trackId ||
        d.ids.fileId !== newStatus.ids.fileId
    );

    const download: Download = {
      ids: newStatus.ids,
      fileType: newStatus.fileType,
      status: newStatus.status,
      receivedBytes: newStatus.receivedBytes,
      totalBytes: newStatus.totalBytes,
      trackDesc: trackDesc,
      lastUpdate: Date.now(),
    };
    this.downloads.unshift(download);

    if (this.downloads.length > this.maxSize) {
      this.downloads.pop();
    }

    store.set(
      anyDownloadErrorsAtom,
      this.downloads.some((d) => d.status === DownloadStatus.ERROR)
    );
  }

  getAll(): Download[] {
    return [...this.downloads]; // return a copy to prevent external mutations
  }

  clear() {
    this.downloads = [];
  }
}

const downloadsStore = memoize(() => new DownloadsStore());
downloadsStore();
export default downloadsStore;
