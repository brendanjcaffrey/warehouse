import axios from "axios";
import { memoize } from "lodash";

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

  constructor() {
    this.pendingUpdates = JSON.parse(
      localStorage.getItem(LOCAL_STORAGE_KEY) || "[]"
    ).filter((value: object) => isUpdate(value));
  }

  setAuthToken(authToken: string | null) {
    this.authToken = authToken;
    this.attemptUpdates();
  }

  async addPlay(trackId: string) {
    const update = { type: "play", trackId, params: undefined };
    if (this.authToken && !this.attemptingBulkUpdates) {
      try {
        await this.attemptUpdate(update);
      } catch (e) {
        console.error("unable to add play", e);
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
    await axios.post(requestPath, update.params, {
      headers: { Authorization: `Bearer ${this.authToken}` },
    });
  }

  private async attemptUpdates() {
    if (this.timerHandler) {
      clearTimeout(this.timerHandler);
      this.timerHandler = undefined;
    }

    if (
      !this.authToken ||
      this.attemptingBulkUpdates ||
      this.pendingUpdates.length === 0
    ) {
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
