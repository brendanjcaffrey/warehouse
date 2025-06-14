export const SyncWorker = new Worker(
  new URL("./SyncManager.ts", import.meta.url),
  {
    type: "module",
  }
);
