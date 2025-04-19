import { memoize, isEqual, shuffle } from "lodash";
import { volumeAtom, shuffleAtom, repeatAtom } from "./Settings";
import {
  store,
  trackUpdatedFnAtom,
  showTrackFnAtom,
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
  SET_SOURCE_REQUESTED_FILES_TYPE,
  FileRequestSource,
  FileType,
  IsTypedMessage,
  IsFileFetchedMessage,
  FileFetchedMessage,
  SetSourceRequestedFilesMessage,
  TrackFileIds,
} from "./WorkerTypes";
import { files } from "./Files";
import { circularArraySlice } from "./Util";
import { TrackFileSet } from "./TrackFileSet";

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
  pendingDownloads: TrackFileSet = new TrackFileSet();
  addingPlay: string | undefined = undefined;

  constructor() {
    files(); // initialize it
    DownloadWorker.addEventListener("message", (m: MessageEvent) => {
      const { data } = m;
      if (!IsTypedMessage(data)) {
        return;
      }
      if (IsFileFetchedMessage(data)) {
        if (data.fileType === FileType.MUSIC) {
          this.handleMusicFetched(data);
        } else {
          this.handleArtworkFetched(data);
        }
      }
    });

    if (navigator.mediaSession) {
      navigator.mediaSession.setActionHandler("play", () => this.play());
      navigator.mediaSession.setActionHandler("pause", () => this.pause());
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
        if (library().getTrackUserChanges()) {
          track.playCount++;
          await library().putTrack(track);
          store.get(trackUpdatedFnAtom).fn(track);
        }
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
      this.playingTrackIds = shuffle(this.playingTrackIds);
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
  play() {
    if (this.playing) {
      return;
    }
    this.playPause();
  }
  pause() {
    if (!this.playing) {
      return;
    }
    this.playPause();
  }
  playPause() {
    if (!this.audioRef || this.playingTrackIds.length === 0) {
      return;
    }

    if (!this.playing) {
      this.trySetPlayingMusicFile();
      this.playing = true;
      this.stopped = false;
      store.set(stoppedAtom, false);
      this.audioPlay();
      this.showPlayingTrackIfInPlaylist();
    } else {
      this.audioRef.pause();
      this.playing = false;
    }
    store.set(playingAtom, this.playing);
  }

  async prev() {
    if (!this.inValidState()) {
      return;
    }

    if (this.inPlayNextList) {
      this.playNextTrackIds.shift();
      this.inPlayNextList = false;
      await this.updatePlayingTrack();
    } else if (this.shouldRewind()) {
      this.audioRef.currentTime = this.playingTrack.start;
      this.audioPlay();
    } else {
      this.playingTrackIdx =
        this.playingTrackIdx === 0
          ? this.playingTrackIds.length - 1
          : this.playingTrackIdx - 1;
      await this.updatePlayingTrack();
    }

    this.showPlayingTrackIfInPlaylist();
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
    this.showPlayingTrackIfInPlaylist();
  }

  // actions
  async playTrack(trackId: string) {
    this.inPlayNextList = false;
    this.playingTrackIds = [];
    await this.rebuildPlayingTrackIds(trackId);
    this.play();
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

  async downloadMusic(trackId: string) {
    const track = await library().getTrack(trackId);
    if (!track) {
      return;
    }
    const ids: TrackFileIds = {
      trackId: track.id,
      fileId: track.fileMd5,
    };

    const url = await files().tryGetFileURL(FileType.MUSIC, track.fileMd5); // TODO release?
    if (url) {
      const a = document.createElement("a");
      a.href = url;
      a.download = `${track.artistName} - ${track.name}.${track.ext}`;
      a.click();
      this.pendingDownloads.delete(ids);
    } else {
      this.pendingDownloads.insert(ids);
      DownloadWorker.postMessage({
        type: SET_SOURCE_REQUESTED_FILES_TYPE,
        source: FileRequestSource.MUSIC_DOWNLOAD,
        fileType: FileType.MUSIC,
        ids: Array.from(this.pendingDownloads.values()),
      } as SetSourceRequestedFilesMessage);
    }
  }

  // helpers
  private handleMusicFetched(data: FileFetchedMessage) {
    if (data.ids.fileId === this.playingTrack?.fileMd5) {
      this.trySetPlayingMusicFile();
    }
    if (this.pendingDownloads.has(data.ids)) {
      this.downloadMusic(data.ids.trackId);
    }
  }

  private handleArtworkFetched(data: FileFetchedMessage) {
    if (
      this.playingTrack &&
      this.playingTrack.artworks.includes(data.ids.fileId)
    ) {
      this.trySetMediaMetadata();
    }
  }

  private async trySetPlayingMusicFile() {
    if (
      !this.playingTrack ||
      !this.audioRef ||
      this.lastSetAudioSrcTrackId === this.playingTrack.id
    ) {
      return;
    }

    const url = await files().tryGetFileURL(
      FileType.MUSIC,
      this.playingTrack.fileMd5
    ); // TODO release?
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
    this.trySetPlayingMusicFile();
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
        ? await files().tryGetFileURL(
            FileType.ARTWORK,
            this.playingTrack.artworks[0]
          )
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

    const musicIds: TrackFileIds[] = [];
    const artworkIds: TrackFileIds[] = [];
    for (const trackId of trackIds) {
      const track = await library().getTrack(trackId);
      if (track) {
        musicIds.push({ trackId: track.id, fileId: track.fileMd5 });
        if (track.artworks.length > 0) {
          artworkIds.push({ trackId: track.id, fileId: track.artworks[0] });
        }
      }
    }
    DownloadWorker.postMessage({
      type: SET_SOURCE_REQUESTED_FILES_TYPE,
      source: FileRequestSource.MUSIC_PRELOAD,
      fileType: FileType.MUSIC,
      ids: musicIds,
    } as SetSourceRequestedFilesMessage);
    DownloadWorker.postMessage({
      type: SET_SOURCE_REQUESTED_FILES_TYPE,
      source: FileRequestSource.ARTWORK_PRELOAD,
      fileType: FileType.ARTWORK,
      ids: artworkIds,
    } as SetSourceRequestedFilesMessage);
  }

  private async showPlayingTrackIfInPlaylist() {
    if (this.playingPlaylistId === this.displayedPlaylistId) {
      store
        .get(showTrackFnAtom)
        .fn(this.playingTrackIds[this.playingTrackIdx], true);
    }
  }
}

export const player = memoize(() => new Player());
