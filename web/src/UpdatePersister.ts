import axios from "axios";
import qs from "qs";
import { memoize } from "lodash";
import { OperationResponse } from "./generated/messages";
import library from "./Library";

const LOCAL_STORAGE_KEY = "updates";
const RETRY_MILLIS = 30000;

export interface Update {
  type: string;
  trackId: string;
  params: object | undefined;
}

function isUpdate(value: object): value is Update {
  return (
    typeof value === "object" &&
    value !== null &&
    "type" in value &&
    "trackId" in value
  );
}

export class UpdatePersister {
  timerHandler: NodeJS.Timeout | undefined = undefined;
  authToken: string | null = null;
  pendingUpdates: Update[] = [];
  attemptingBulkUpdates: boolean = false;
  hasLibraryMetadata: boolean = false;

  constructor() {
    this.pendingUpdates = JSON.parse(
      localStorage.getItem(LOCAL_STORAGE_KEY) || "[]"
    ).filter((value: object) => isUpdate(value));
  }

  setAuthToken(authToken: string | null) {
    this.authToken = authToken;
    this.attemptUpdates();
  }

  setHasLibraryMetadata(value: boolean) {
    this.hasLibraryMetadata = value;
    this.attemptUpdates();
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
    const update = { type: "play", trackId, params: undefined };
    await this.handleUpdate(update);
  }

  async updateRating(trackId: string, rating: number) {
    const update = { type: "rating", trackId, params: { rating } };
    await this.handleUpdate(update);
  }

  async updateTrackInfo(trackId: string, updatedFields: object) {
    const update = { type: "track-info", trackId, params: updatedFields };
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
    if (!isUpdate(update)) {
      console.error("invalid update", update);
      return;
    }
    this.pendingUpdates.push(update);
    this.persistUpdates();
    this.setTimer();
  }

  private async attemptUpdate(update: Update) {
    if (!isUpdate(update)) {
      console.error("invalid update", update);
      return;
    }
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
