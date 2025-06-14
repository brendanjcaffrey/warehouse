export const DownloadWorker = new Worker(
  new URL("./DownloadManager.ts", import.meta.url),
  {
    type: "module",
  }
);
