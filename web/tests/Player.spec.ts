import { beforeEach, expect, test, vi } from "vitest";
import type { Track } from "../src/Library";

const tracks = new Map<string, Track>();

vi.mock("../src/DownloadWorker", () => ({
  DownloadWorker: { addEventListener: vi.fn(), postMessage: vi.fn() },
}));
vi.mock("../src/Files", () => ({
  files: () => ({ tryGetFileURL: async () => "blob:music" }),
}));
vi.mock("../src/UpdatePersister", () => ({
  updatePersister: () => ({ addPlay: vi.fn() }),
}));
vi.mock("../src/Library", () => ({
  default: () => ({
    getTrack: async (id: string) => tracks.get(id),
    getTrackUserChanges: () => false,
    putTrack: async () => {},
  }),
}));

const { player } = await import("../src/Player");

function track(id: string, start = 0): Track {
  return {
    id,
    name: id,
    duration: 300,
    start,
    finish: 300,
    musicFilename: `${id}.mp3`,
    artworkFilename: null,
    playlistIds: [],
  } as unknown as Track;
}

// the audio element the player drives, enough of one for playback bookkeeping
function fakeAudio() {
  return {
    src: "",
    currentTime: 0,
    volume: 1,
    seeking: false,
    readyState: 4,
    ended: false,
    play: vi.fn().mockResolvedValue(undefined),
    pause: vi.fn(),
  } as unknown as HTMLAudioElement;
}

// the player kicks off file loading without awaiting it
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

let audio: HTMLAudioElement;
const rows = [track("t1", 5), track("t2")];

beforeEach(async () => {
  URL.revokeObjectURL = vi.fn();
  tracks.clear();
  for (const t of rows) {
    tracks.set(t.id, t);
  }
  await player().reset();
  audio = fakeAudio();
  player().setAudioRef(audio);
});

test("playing the track that is already playing restarts it", async () => {
  await player().playTracks("library", rows, 0);
  await settle();
  audio.currentTime = 42;

  await player().playTracks("library", rows, 0);

  expect(player().playingTrack?.track.id).toBe("t1");
  expect(audio.currentTime).toBe(5);
});

test("restarting the playing track resumes it when it was paused", async () => {
  await player().playTracks("library", rows, 0);
  await settle();
  player().pause();
  audio.currentTime = 42;

  await player().playTracks("library", rows, 0);

  expect(audio.currentTime).toBe(5);
  expect(player().playing).toBe(true);
});

test("playing a different track moves to that track's start", async () => {
  await player().playTracks("library", rows, 0);
  await settle();
  audio.currentTime = 42;

  await player().playTracks("library", rows, 1);
  await settle();

  expect(player().playingTrack?.track.id).toBe("t2");
  expect(audio.currentTime).toBe(0);
});
