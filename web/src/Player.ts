import { memoize, isEqual } from "lodash";
import { volumeAtom, shuffleAtom, repeatAtom } from "./Settings";
import {
  store,
  stoppedAtom,
  currentTimeAtom,
  playingTrackAtom,
  playingAtom,
} from "./State";
import library, { Track } from "./Library";
import { DownloadWorker } from "./DownloadWorkerHandle";
import {
  isTypedMessage,
  isTrackFetchedMessage,
  FETCH_TRACK_TYPE,
  FETCH_ARTWORK_TYPE,
} from "./WorkerTypes";
import { circularArraySlice } from "./Util";

const TRACKS_TO_PRELOAD = 3;

class Player {
  trackDirHandle: FileSystemDirectoryHandle | undefined;
  audioRef: HTMLAudioElement | undefined;

  // what is displayed in the track table
  displayedPlaylistId: string | undefined;
  displayedTrackIds: string[];

  // what we're playing right now - can be different from displayed
  playingPlaylistId: string | undefined;
  // tracks sorted in the order they are displayed in
  sortedPlayingTrackIds: string[];
  // tracks sorted in the order we are playing them - can be different than above if shuffle is on
  playingTrackIds: string[];
  // index into playingTrackIds
  playingTrackIdx: number;
  playingTrack: Track | undefined;
  // last track we set the audio src to, here to avoid setting it to the same thing
  lastSetAudioSrcTrackId: string | undefined;

  // stopped is true at load, then false forever after the first track is played
  stopped: boolean;
  // whether actively playing or paused
  playing: boolean;

  pendingDownloads: Set<string> = new Set();

  constructor() {
    this.trackDirHandle = undefined;
    this.audioRef = undefined;
    this.displayedPlaylistId = undefined;
    this.displayedTrackIds = [];
    this.playingPlaylistId = undefined;
    this.sortedPlayingTrackIds = [];
    this.playingTrackIds = [];
    this.playingTrackIdx = 0;
    this.playingTrack = undefined;
    this.lastSetAudioSrcTrackId = undefined;
    this.stopped = true;
    this.playing = false;

    this.getTrackDirHandle();
    DownloadWorker.addEventListener("message", (m: MessageEvent) => {
      const { data } = m;
      if (!isTypedMessage(data) || !isTrackFetchedMessage(data)) {
        return;
      }
      if (data.trackFilename === this.playingTrack?.id) {
        this.trySetPlayingTrack();
      }
      if (this.pendingDownloads.has(data.trackFilename)) {
        this.downloadTrack(data.trackFilename);
      }
    });
  }

  setAudioRef(audioRef: HTMLAudioElement) {
    this.audioRef = audioRef;
    this.setVolume(store.get(volumeAtom));
    this.audioRef.ontimeupdate = () => {
      const currentTime = this.audioRef!.currentTime;
      store.set(currentTimeAtom, currentTime);

      if (!this.playingTrack) {
        return;
      }
      if (
        currentTime >= this.playingTrack.finish ||
        currentTime >= this.playingTrack.duration
      ) {
        // TODO record play
        this.next();
      }
    };
  }

  setVolume(volume: number) {
    if (this.audioRef) {
      this.audioRef.volume = volume / 100.0;
    }
    store.set(volumeAtom, volume);
  }

  setCurrentTime(time: number) {
    if (this.audioRef) {
      this.audioRef.currentTime = time;
    }
    store.set(currentTimeAtom, time);
  }

  async setDisplayedTrackIds(
    displayedPlaylistId: string,
    displayedTrackIds: string[]
  ) {
    if (
      displayedPlaylistId === this.displayedPlaylistId &&
      isEqual(this.displayedTrackIds, displayedTrackIds)
    ) {
      return;
    }

    this.displayedPlaylistId = displayedPlaylistId;
    this.displayedTrackIds = displayedTrackIds;
    if (this.stopped || this.displayedPlaylistId === this.playingPlaylistId) {
      this.playingPlaylistId = this.displayedPlaylistId;
      this.sortedPlayingTrackIds = [...this.displayedTrackIds];
      await this.shuffleChanged();
    }
  }

  async shuffleChanged() {
    this.playingTrackIds = [...this.sortedPlayingTrackIds];
    if (store.get(shuffleAtom)) {
      this.playingTrackIds.sort(() => Math.random() - 0.5);
    }

    if (this.stopped) {
      this.playingTrackIdx = 0;
      await this.updatePlayingTrack();
    } else {
      this.playingTrackIdx = this.playingTrackIds.indexOf(
        this.playingTrack!.id
      );
    }
  }

  // controls
  playPause() {
    if (!this.audioRef || this.playingTrackIds.length === 0) {
      return;
    }

    if (!this.playing) {
      this.trySetPlayingTrack();
      this.playing = true;
      this.stopped = false;
      store.set(stoppedAtom, false);
      this.audioPlay();
    } else {
      this.audioRef.pause();
      this.playing = false;
    }
    store.set(playingAtom, this.playing);
  }

  prev() {
    if (!this.inValidState()) {
      return;
    }

    if (this.shouldRewind()) {
      this.audioRef.currentTime = this.playingTrack.start;
      this.audioPlay();
    } else {
      this.playingTrackIdx =
        this.playingTrackIdx === 0
          ? this.playingTrackIds.length - 1
          : this.playingTrackIdx - 1;
      this.updatePlayingTrack();
    }
  }

  next() {
    if (!this.inValidState()) {
      return;
    }

    // TODO check play next list
    if (this.shouldRewind()) {
      this.audioRef.currentTime = this.playingTrack.start;
      this.audioPlay();
    } else {
      this.playingTrackIdx =
        (this.playingTrackIdx + 1) % this.playingTrackIds.length;
      this.updatePlayingTrack();
    }
  }

  // actions
  playTrack(trackId: string) {}

  playTrackNext(trackId: string) {}

  async downloadTrack(trackId: string) {
    const track = await library().getTrack(trackId);
    if (!track) {
      return;
    }

    const file = await this.tryGetTrackFile(trackId);
    if (file) {
      const a = document.createElement("a");
      a.href = URL.createObjectURL(file);
      a.download = `${track.artistName} - ${track.name}.${track.ext}`;
      a.click();
      this.pendingDownloads.delete(trackId);
    } else {
      this.pendingDownloads.add(trackId);
      DownloadWorker.postMessage({
        type: FETCH_TRACK_TYPE,
        trackFilename: trackId,
      });
    }
  }

  // helpers
  private async getTrackDirHandle() {
    try {
      const mainDir = await navigator.storage.getDirectory();
      this.trackDirHandle = await mainDir.getDirectoryHandle("track", {
        create: true,
      });
    } catch (e) {
      console.error("unable to get tracks dir handle", e);
    }
  }

  private async trySetPlayingTrack() {
    if (
      !this.playingTrack ||
      !this.audioRef ||
      this.lastSetAudioSrcTrackId === this.playingTrack.id
    ) {
      return;
    }

    try {
      const file = await this.tryGetTrackFile(this.playingTrack.id);
      this.audioRef.src = URL.createObjectURL(file!);
      this.audioRef.currentTime = this.playingTrack.start;
      this.lastSetAudioSrcTrackId = this.playingTrack.id;
      if (this.playing) {
        this.audioPlay();
      }
    } catch {
      this.audioRef.pause();
    }
  }

  private async tryGetTrackFile(trackId: string) {
    try {
      const fileHandle = await this.trackDirHandle!.getFileHandle(trackId);
      return await fileHandle.getFile();
    } catch {
      return null;
    }
  }

  private audioPlay() {
    this.audioRef?.play().catch(() => {
      // nop, this happens when the user pauses the audio
    });
  }

  private shouldRewind() {
    return store.get(repeatAtom) || this.playingTrackIds.length === 1;
  }

  private inValidState(): this is {
    audioRef: HTMLAudioElement;
    playingTrack: Track;
    playingTrackIds: string[];
  } {
    return (
      this.audioRef !== undefined &&
      this.playingTrack !== undefined &&
      this.playingTrackIds.length > 0
    );
  }

  private async updatePlayingTrack() {
    if (this.playingTrackIds.length === 0) {
      return;
    }

    this.playingTrack = await library().getTrack(
      this.playingTrackIds[this.playingTrackIdx]
    );
    store.set(playingTrackAtom, this.playingTrack);
    this.trySetPlayingTrack();

    // preload the tracks
    for (const trackId of circularArraySlice(
      this.playingTrackIds,
      this.playingTrackIdx,
      TRACKS_TO_PRELOAD
    )) {
      DownloadWorker.postMessage({
        type: FETCH_TRACK_TYPE,
        trackFilename: trackId,
      });

      const track = await library().getTrack(trackId);
      if (track && track.artworks.length > 0) {
        DownloadWorker.postMessage({
          type: FETCH_ARTWORK_TYPE,
          artworkFilename: track.artworks[0],
        });
      }
    }
  }
}

export const player = memoize(() => new Player());
