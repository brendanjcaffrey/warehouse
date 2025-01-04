export const DownloadWorker = new Worker(
  new URL("./DownloadWorker.ts", import.meta.url),
  {
    type: "module",
  }
);
