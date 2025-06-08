import axios from "axios";
import qs from "qs";
import { memoize } from "lodash";
import { OperationResponse } from "./generated/messages";
import library from "./Library";
import { DownloadWorker } from "./DownloadWorkerHandle";
import {
  FileRequestSource,
  FileType,
  SET_SOURCE_REQUESTED_FILES_TYPE,
} from "./WorkerTypes";
import { files } from "./Files";

const LOCAL_STORAGE_KEY = "updates";
const RETRY_MILLIS = 30000;

type PlayUpdate = {
  type: "play";
  trackId: string;
  params: undefined;
};

type RatingUpdate = {
  type: "rating";
  trackId: string;
  params: { rating: number };
};

type TrackInfoUpdate = {
  type: "track-info";
  trackId: string;
  params: object;
};

type ArtworkUpload = {
  type: "artwork";
  trackId: undefined;
  params: { filename: string };
};

export type Update =
  | PlayUpdate
  | RatingUpdate
  | TrackInfoUpdate
  | ArtworkUpload;

function IsUpdate(value: object): value is Update {
  return (
    typeof value === "object" &&
    value !== null &&
    "type" in value &&
    (value.type == "artwork" || "trackId" in value) &&
    (value.type == "play" || "params" in value)
  );
}

function IsArtworkUpload(value: object): value is ArtworkUpload {
  return (
    IsUpdate(value) &&
    value.type === "artwork" &&
    value.trackId === undefined &&
    typeof value.params.filename === "string"
  );
}

export class UpdatePersister {
  timerHandler: NodeJS.Timeout | undefined = undefined;
  authToken: string | null = null;
  pendingUpdates: Update[] = [];
  attemptingBulkUpdates: boolean = false;
  hasLibraryMetadata: boolean = false;
  requestedArtworkFiles: Set<string>;

  constructor() {
    this.pendingUpdates = JSON.parse(
      localStorage.getItem(LOCAL_STORAGE_KEY) || "[]"
    ).filter((value: object) => IsUpdate(value));

    this.requestedArtworkFiles = new Set(
      this.pendingUpdates
        .filter((e) => IsArtworkUpload(e))
        .map((e) => e.params.filename)
    );
    this.requestFiles();
  }

  private requestFiles() {
    DownloadWorker.postMessage({
      type: SET_SOURCE_REQUESTED_FILES_TYPE,
      source: FileRequestSource.UPDATE_PERSISTER,
      fileType: FileType.ARTWORK,
      ids: this.requestedArtworkFiles
        .keys()
        .map((filename) => ({
          trackId: undefined,
          fileId: filename,
        }))
        .toArray(),
    });
  }

  async setAuthToken(authToken: string | null) {
    this.authToken = authToken;
    await this.attemptUpdates();
  }

  async setHasLibraryMetadata(value: boolean) {
    this.hasLibraryMetadata = value;
    await this.attemptUpdates();
  }

  clearPending() {
    this.pendingUpdates = [];
    this.persistUpdates();
  }

  private shouldAttemptUpdate(update: Update): boolean {
    if (!this.hasLibraryMetadata) {
      this.addPendingUpdate(update);
      return false;
    }

    if (!library().getTrackUserChanges()) {
      return false;
    }

    return true;
  }

  async addPlay(trackId: string) {
    const update: PlayUpdate = { type: "play", trackId, params: undefined };
    await this.handleUpdate(update);
  }

  async updateRating(trackId: string, rating: number) {
    const update: RatingUpdate = {
      type: "rating",
      trackId,
      params: { rating },
    };
    await this.handleUpdate(update);
  }

  async updateTrackInfo(trackId: string, updatedFields: object) {
    const update: TrackInfoUpdate = {
      type: "track-info",
      trackId,
      params: updatedFields,
    };
    await this.handleUpdate(update);
  }

  async uploadArtwork(artworkFilename: string) {
    if (
      this.pendingUpdates.some(
        (e) => IsArtworkUpload(e) && e.params.filename === artworkFilename
      )
    ) {
      return;
    }

    this.requestedArtworkFiles.add(artworkFilename);
    this.requestFiles();

    const update: ArtworkUpload = {
      type: "artwork",
      trackId: undefined,
      params: { filename: artworkFilename },
    };
    await this.handleUpdate(update);
  }

  private async handleUpdate(update: Update) {
    if (!this.shouldAttemptUpdate(update)) {
      return;
    }

    if (this.authToken && !this.attemptingBulkUpdates) {
      try {
        await this.attemptUpdate(update);
      } catch (e) {
        console.error(`unable to handle ${update.type} update`, e);
        this.addPendingUpdate(update);
      }
    } else {
      this.addPendingUpdate(update);
    }
  }

  private addPendingUpdate(update: Update) {
    if (!IsUpdate(update)) {
      console.error("invalid update", update);
      return;
    }
    this.pendingUpdates.push(update);
    this.persistUpdates();
    this.setTimer();
  }

  private async attemptUpdate(update: Update) {
    if (!IsUpdate(update)) {
      console.error("invalid update", update);
      return;
    }

    if (IsArtworkUpload(update)) {
      await this.attemptArtworkUpdate(update);
    } else {
      await this.attemptTrackUpdate(update);
    }
  }

  private async attemptArtworkUpdate(upload: ArtworkUpload) {
    const requestPath = `/api/${upload.type}`;
    const file = await files().tryReadFile(
      FileType.ARTWORK,
      upload.params.filename
    );
    if (!file) {
      throw new Error("Can't read artwork file");
    }

    var formData = new FormData();
    formData.append("file", file, upload.params.filename);
    const { data } = await axios.post(requestPath, formData, {
      responseType: "arraybuffer",
      headers: {
        Authorization: `Bearer ${this.authToken}`,
        "Content-Type": "multipart/form-data",
      },
    });

    const resp = OperationResponse.deserialize(data);
    if (resp.success) {
      this.requestedArtworkFiles.delete(upload.params.filename);
      this.requestFiles();
    } else {
      throw new Error(resp.error);
    }
  }

  private async attemptTrackUpdate(update: Update) {
    const requestPath = `/api/${update.type}/${update.trackId}`;
    const { data } = await axios.post(
      requestPath,
      qs.stringify(update.params),
      {
        responseType: "arraybuffer",
        headers: {
          Authorization: `Bearer ${this.authToken}`,
          "Content-Type": "application/x-www-form-urlencoded",
        },
      }
    );
    const resp = OperationResponse.deserialize(data);
    if (!resp.success) {
      throw new Error(resp.error);
    }
  }

  private async attemptUpdates() {
    if (this.timerHandler) {
      clearTimeout(this.timerHandler);
      this.timerHandler = undefined;
    }

    if (
      !this.authToken ||
      !this.hasLibraryMetadata ||
      this.attemptingBulkUpdates ||
      this.pendingUpdates.length === 0
    ) {
      return;
    }

    if (!library().getTrackUserChanges()) {
      this.clearPending();
      return;
    }

    this.attemptingBulkUpdates = true;
    let updateIndex = 0;
    while (updateIndex < this.pendingUpdates.length) {
      try {
        const update = this.pendingUpdates[updateIndex];
        await this.attemptUpdate(update);
        this.pendingUpdates.splice(updateIndex, 1);
      } catch (e) {
        console.error(
          "unable to send update",
          this.pendingUpdates[updateIndex],
          e
        );
        updateIndex++;
      }
      this.persistUpdates();
    }

    this.attemptingBulkUpdates = false;
    this.setTimer();
  }

  private persistUpdates() {
    localStorage.setItem(
      LOCAL_STORAGE_KEY,
      JSON.stringify(this.pendingUpdates)
    );
  }

  private setTimer() {
    if (
      !this.timerHandler &&
      this.pendingUpdates.length > 0 &&
      this.authToken
    ) {
      this.timerHandler = setTimeout(() => this.attemptUpdates(), RETRY_MILLIS);
    }
  }
}

export const updatePersister = memoize(() => new UpdatePersister());
