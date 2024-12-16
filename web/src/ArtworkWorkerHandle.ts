export const ArtworkWorker = new Worker(
  new URL("./ArtworkWorker.ts", import.meta.url),
  {
    type: "module",
  }
);
