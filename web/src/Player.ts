import { memoize, isEqual } from "lodash";
import { volumeAtom, shuffleAtom, repeatAtom } from "./Settings";
import {
  store,
  trackUpdatedFnAtom,
  stoppedAtom,
  currentTimeAtom,
  playingTrackAtom,
  playingAtom,
  resetAllState,
} from "./State";
import library, { Track } from "./Library";
import { DownloadWorker } from "./DownloadWorkerHandle";
import { updatePersister } from "./UpdatePersister";
import {
  isTypedMessage,
  isTrackFetchedMessage,
  isArtworkFetchedMessage,
  FETCH_TRACK_TYPE,
  FETCH_ARTWORK_TYPE,
  ArtworkFetchedMessage,
  TrackFetchedMessage,
} from "./WorkerTypes";
import { files } from "./Files";
import { circularArraySlice } from "./Util";

const TRACKS_TO_PRELOAD = 3;

class Player {
  audioRef: HTMLAudioElement | undefined = undefined;

  // what is displayed in the track table
  displayedPlaylistId: string | undefined = undefined;
  displayedTrackIds: string[] = [];

  // what we're playing right now - can be different from displayed
  playingPlaylistId: string | undefined = undefined;
  // tracks sorted in the order they are displayed in
  sortedPlayingTrackIds: string[] = [];
  // tracks sorted in the order we are playing them - can be different than above if shuffle is on
  playingTrackIds: string[] = [];
  // a list of songs to play next, distinct from the main playlist
  playNextTrackIds: string[] = [];
  // index into playingTrackIds
  playingTrackIdx: number = 0;
  inPlayNextList: boolean = false;
  playingTrack: Track | undefined = undefined;
  // last track we set the audio src to, here to avoid setting it to the same thing
  lastSetAudioSrcTrackId: string | undefined = undefined;

  // stopped is true at load, then false forever after the first track is played
  stopped: boolean = true;
  // whether actively playing or paused
  playing: boolean = false;

  // TODO timeout, show error etc
  pendingDownloads: Set<string> = new Set();
  addingPlay: string | undefined = undefined;

  constructor() {
    files(); // initialize it
    DownloadWorker.addEventListener("message", (m: MessageEvent) => {
      const { data } = m;
      if (!isTypedMessage(data)) {
        return;
      }
      if (isTrackFetchedMessage(data)) {
        this.handleTrackFetched(data);
      }
      if (isArtworkFetchedMessage(data)) {
        this.handleArtworkFetched(data);
      }
    });

    if (navigator.mediaSession) {
      navigator.mediaSession.setActionHandler("play", () => this.playPause());
      navigator.mediaSession.setActionHandler("pause", () => this.playPause());
      navigator.mediaSession.setActionHandler("nexttrack", () => this.next());
      navigator.mediaSession.setActionHandler("previoustrack", () =>
        this.prev()
      );
    }
  }

  async reset() {
    this.audioRef = undefined;
    this.displayedPlaylistId = undefined;
    this.displayedTrackIds = [];
    this.playingPlaylistId = undefined;
    this.sortedPlayingTrackIds = [];
    this.playingTrackIds = [];
    this.playNextTrackIds = [];
    this.playingTrackIdx = 0;
    this.inPlayNextList = false;
    this.playingTrack = undefined;
    this.lastSetAudioSrcTrackId = undefined;
    this.stopped = true;
    this.playing = false;
    resetAllState();
  }

  setAudioRef(audioRef: HTMLAudioElement) {
    this.setVolume(store.get(volumeAtom));

    this.audioRef = audioRef;
    this.audioRef.onended = () => {
      this.trackFinished();
    };
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
        this.trackFinished();
      }
    };
  }

  private async trackFinished() {
    if (!this.playingTrack) {
      return;
    }
    // make sure two ontimeupdate events don't trigger two next() calls
    if (this.addingPlay === this.playingTrack.id) {
      return;
    }

    this.addingPlay = this.playingTrack.id;
    try {
      this.audioRef!.pause();
      updatePersister().addPlay(this.playingTrack.id);
      // always get the latest version of the track just in case it was updated
      const track = await library().getTrack(this.playingTrack.id);
      if (track) {
        track.playCount++;
        await library().putTrack(track);
        store.get(trackUpdatedFnAtom).fn(track);
        this.playingTrack = track;
      }
      await this.next();
    } finally {
      this.addingPlay = undefined;
    }
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
      this.rebuildPlayingTrackIds();
    }
  }

  async rebuildPlayingTrackIds(
    overwritePlayingTrackId: string | undefined = undefined
  ) {
    this.playingPlaylistId = this.displayedPlaylistId;
    this.sortedPlayingTrackIds = [...this.displayedTrackIds];
    await this.shuffleChanged(overwritePlayingTrackId);
  }

  async shuffleChanged(
    overwritePlayingTrackId: string | undefined = undefined
  ) {
    this.playingTrackIds = [...this.sortedPlayingTrackIds];
    if (store.get(shuffleAtom)) {
      this.playingTrackIds.sort(() => Math.random() - 0.5);
    }

    if (overwritePlayingTrackId) {
      this.playingTrackIdx = this.playingTrackIds.indexOf(
        overwritePlayingTrackId
      );
      await this.updatePlayingTrack();
    } else if (this.stopped) {
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
      this.trySetPlayingTrackFile();
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

    if (this.inPlayNextList) {
      this.playNextTrackIds.shift();
      this.inPlayNextList = false;
      this.updatePlayingTrack();
    } else if (this.shouldRewind()) {
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

  async next() {
    if (!this.inValidState()) {
      return;
    }

    const wasInPlayNextList = this.inPlayNextList;
    if (this.inPlayNextList) {
      this.playNextTrackIds.shift();
    }
    this.inPlayNextList = this.playNextTrackIds.length > 0;

    if (this.inPlayNextList) {
      await this.updatePlayingTrack();
    } else if (this.shouldRewind()) {
      if (wasInPlayNextList) {
        await this.updatePlayingTrack();
      }
      this.audioRef.currentTime = this.playingTrack.start;
      this.audioPlay();
    } else {
      this.playingTrackIdx =
        (this.playingTrackIdx + 1) % this.playingTrackIds.length;
      await this.updatePlayingTrack();
    }
  }

  // actions
  playTrack(trackId: string) {
    this.inPlayNextList = false;
    this.playingTrackIds = [];
    this.rebuildPlayingTrackIds(trackId);
    if (this.stopped) {
      this.playPause();
    }
  }

  async playTrackNext(trackId: string) {
    if (this.inPlayNextList) {
      // add after the current play next track
      this.playNextTrackIds.splice(1, 0, trackId);
    } else {
      this.playNextTrackIds.unshift(trackId);
    }
    await this.preloadTracks();
  }

  async downloadTrack(trackId: string) {
    const track = await library().getTrack(trackId);
    if (!track) {
      return;
    }

    const url = await files().tryGetTrackURL(trackId); // TODO release?
    if (url) {
      const a = document.createElement("a");
      a.href = url;
      a.download = `${track.artistName} - ${track.name}.${track.ext}`;
      a.click();
      this.pendingDownloads.delete(trackId);
    } else {
      this.pendingDownloads.add(trackId);
      DownloadWorker.postMessage({
        type: FETCH_TRACK_TYPE,
        trackId: trackId,
      });
    }
  }

  // helpers
  private handleTrackFetched(data: TrackFetchedMessage) {
    if (data.trackId === this.playingTrack?.id) {
      this.trySetPlayingTrackFile();
    }
    if (this.pendingDownloads.has(data.trackId)) {
      this.downloadTrack(data.trackId);
    }
  }

  private handleArtworkFetched(data: ArtworkFetchedMessage) {
    if (
      this.playingTrack &&
      this.playingTrack.artworks.includes(data.artworkId)
    ) {
      this.trySetMediaMetadata();
    }
  }
  private async trySetPlayingTrackFile() {
    if (
      !this.playingTrack ||
      !this.audioRef ||
      this.lastSetAudioSrcTrackId === this.playingTrack.id
    ) {
      return;
    }

    const url = await files().tryGetTrackURL(this.playingTrack.id); // TODO release?
    if (url) {
      this.audioRef.src = url;
      this.audioRef.currentTime = this.playingTrack.start;
      this.lastSetAudioSrcTrackId = this.playingTrack.id;
      if (this.playing) {
        this.audioPlay();
      }
    } else {
      this.audioRef.pause();
    }
  }

  private audioPlay() {
    if (this.lastSetAudioSrcTrackId !== this.playingTrack?.id) {
      return;
    }
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
    if (
      this.playingTrackIds.length === 0 &&
      this.playNextTrackIds.length === 0
    ) {
      return;
    }

    if (this.inPlayNextList) {
      this.playingTrack = await library().getTrack(this.playNextTrackIds[0]);
    } else {
      this.playingTrack = await library().getTrack(
        this.playingTrackIds[this.playingTrackIdx]
      );
    }
    store.set(playingTrackAtom, this.playingTrack);
    this.trySetMediaMetadata();
    this.trySetPlayingTrackFile();
    await this.preloadTracks();
  }

  private async trySetMediaMetadata() {
    if (!navigator.mediaSession || !this.playingTrack) {
      return;
    }

    const metadata = new MediaMetadata({
      title: this.playingTrack.name,
      artist: this.playingTrack.artistName,
      album: this.playingTrack.albumName,
      artwork: [],
    });

    // NB: media metadata artwork not working in Firefox but does in Chrome
    const url =
      this.playingTrack.artworks.length > 0
        ? await files().tryGetArtworkURL(this.playingTrack.artworks[0])
        : null; // TODO release?
    if (url) {
      // XXX if you update this, update the type detection in library.rb
      const ext = this.playingTrack.artworks[0].split(".").pop();
      switch (ext) {
        case "jpg":
          metadata.artwork = [{ src: url, type: "image/jpeg" }];
          break;
        case "png":
          metadata.artwork = [{ src: url, type: "image/png" }];
          break;
      }
    }
    navigator.mediaSession.metadata = metadata;
  }

  private async preloadTracks() {
    let trackIds = circularArraySlice(
      this.playingTrackIds,
      this.playingTrackIdx,
      TRACKS_TO_PRELOAD
    );
    trackIds = [...trackIds, ...this.playNextTrackIds];

    // preload the tracks
    for (const trackId of trackIds) {
      DownloadWorker.postMessage({
        type: FETCH_TRACK_TYPE,
        trackId,
      });

      const track = await library().getTrack(trackId);
      if (track && track.artworks.length > 0) {
        DownloadWorker.postMessage({
          type: FETCH_ARTWORK_TYPE,
          artworkId: track.artworks[0],
        });
      }
    }
  }
}

export const player = memoize(() => new Player());
