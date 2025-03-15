import { memoize } from "lodash";
import library from "./Library";
import {
  FileDownloadStatusMessage,
  TrackFileIds,
  FileType,
  DownloadStatus,
} from "./WorkerTypes";

const DEFAULT_MAX_SIZE = 100;

export interface Download {
  ids: TrackFileIds;
  fileType: FileType;
  status: DownloadStatus;
  receivedBytes: number;
  totalBytes: number;
  trackName: string;
  lastUpdate: number;
}

export class DownloadsStore {
  private downloads: Download[] = [];
  private maxSize: number;

  constructor(maxSize: number = DEFAULT_MAX_SIZE) {
    this.maxSize = maxSize;
  }

  async update(newStatus: FileDownloadStatusMessage) {
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
      trackName: "[pending]",
      lastUpdate: Date.now(),
    };
    this.downloads.unshift(download);

    if (this.downloads.length > this.maxSize) {
      this.downloads.pop();
    }

    const track = await library().getTrack(newStatus.ids.trackId);
    if (track) {
      download.trackName = `${track.name} - ${track.artistName}`;
    }
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
