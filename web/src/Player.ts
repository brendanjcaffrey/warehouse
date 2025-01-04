import { memoize, isEqual } from "lodash";
import { volumeAtom, shuffleAtom } from "./Settings";
import { store, currentTimeAtom, playingTrackAtom, playingAtom } from "./State";
import library, { Track } from "./Library";
import { DownloadWorker } from "./DownloadWorkerHandle";
import {
  isTypedMessage,
  isFetchTrackMessage,
  FETCH_TRACK_TYPE,
} from "./WorkerTypes";
import { circularArraySlice } from "./Util";

const TRACKS_TO_PRELOAD = 3;

class Player {
  trackDirHandle: FileSystemDirectoryHandle | undefined;
  audioRef: HTMLAudioElement | undefined;
  displayedTrackIds: string[];
  playingTrackIds: string[];
  playingTrackIdx: number;
  playingTrack: Track | undefined;
  lastSetAudioSrcTrackId: string | undefined;
  everPlayed: boolean;
  playing: boolean;

  constructor() {
    this.trackDirHandle = undefined;
    this.audioRef = undefined;
    this.displayedTrackIds = [];
    this.playingTrackIds = [];
    this.playingTrackIdx = 0;
    this.playingTrack = undefined;
    this.lastSetAudioSrcTrackId = undefined;
    this.everPlayed = false;
    this.playing = false;

    this.getTrackDirHandle();
    DownloadWorker.onmessage = (m: MessageEvent) => {
      const { data } = m;
      if (!isTypedMessage(data)) {
        return;
      }
      if (
        isFetchTrackMessage(data) &&
        data.trackFilename === this.playingTrack?.id
      ) {
        this.trySetPlayingTrack();
      }
    };
  }

  async trySetPlayingTrack() {
    if (!this.playingTrack || !this.audioRef) {
      return;
    }
    try {
      if (this.lastSetAudioSrcTrackId === this.playingTrack.id) {
        return;
      }
      const fileHandle = await this.trackDirHandle?.getFileHandle(
        this.playingTrack.id
      );
      const file = await fileHandle!.getFile();
      this.audioRef.src = URL.createObjectURL(file);
      this.audioRef.currentTime = this.playingTrack.start;
      this.lastSetAudioSrcTrackId = this.playingTrack.id;
    } catch {
      // nop
    }
  }

  async getTrackDirHandle() {
    try {
      const mainDir = await navigator.storage.getDirectory();
      this.trackDirHandle = await mainDir.getDirectoryHandle("track", {
        create: true,
      });
    } catch (e) {
      console.error("unable to get tracks dir handle", e);
    }
  }

  setAudioRef(audioRef: HTMLAudioElement) {
    this.audioRef = audioRef;
    this.setVolume(store.get(volumeAtom));
    this.audioRef.ontimeupdate = () => {
      store.set(currentTimeAtom, this.audioRef!.currentTime);
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

  async setDisplayedTrackIds(displayedTrackIds: string[]) {
    if (isEqual(this.displayedTrackIds, displayedTrackIds)) {
      return;
    }

    if (!this.everPlayed) {
      if (store.get(shuffleAtom)) {
        this.playingTrackIds = displayedTrackIds.sort(
          () => Math.random() - 0.5
        );
      } else {
        this.playingTrackIds = [...displayedTrackIds];
      }
      this.playingTrackIdx = 0;
      this.playingTrack = await library().getTrack(
        this.playingTrackIds[this.playingTrackIdx]
      );
      store.set(playingTrackAtom, this.playingTrack);
      this.trySetPlayingTrack();

      // preload the tracks
      for (const track of circularArraySlice(
        this.playingTrackIds,
        this.playingTrackIdx,
        TRACKS_TO_PRELOAD
      )) {
        DownloadWorker.postMessage({
          type: FETCH_TRACK_TYPE,
          trackFilename: track,
        });
      }
    }
  }

  // controls
  playPause() {
    if (!this.audioRef || this.playingTrackIds.length === 0) {
      return;
    }

    if (!this.playing) {
      this.playing = true;
      this.everPlayed = true;
      this.audioRef.play();
    } else {
      this.audioRef.pause();
      this.playing = false;
    }
    store.set(playingAtom, this.playing);
  }

  prev() {
    console.log("prev");
  }

  next() {
    console.log("next");
  }

  // actions
  playTrack(trackId: string) {}

  playTrackNext(trackId: string) {}
}

export const player = memoize(() => new Player());
