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
  waitingForMusicDownloadAtom,
  typeToShowInProgressAtom,
  resetAllState,
} from "./State";
import library, { Track } from "./Library";
import { DownloadWorker } from "./DownloadWorker";
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
import { PlayingTrack, DisplayedTrack, PlaylistTrack } from "./Types";
import { IMAGE_EXTENSION_TO_MIME } from "./MimeTypes";

const TRACKS_TO_PRELOAD = 3;

class Player {
  audioRef: HTMLAudioElement | undefined = undefined;

  // what is displayed in the track table
  displayedPlaylistId: string | undefined = undefined;
  displayedTracks: DisplayedTrack[] = [];

  // what playlist is playing right now - can be different from displayed
  playingPlaylistId: string | undefined = undefined;
  // tracks sorted in the order they are displayed in
  sortedPlayingTracks: DisplayedTrack[] = [];
  // tracks sorted in the order we are playing them - can be different than above if shuffle is on
  playingTracks: DisplayedTrack[] = [];

  // a list of songs to play next, distinct from the playing playlist
  playNextTracks: PlaylistTrack[] = [];

  // index into playingTracks
  playingTrackIdx: number = 0;
  inPlayNextList: boolean = false;
  playingTrack: PlayingTrack | undefined = undefined;
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

    document.addEventListener("keydown", (event: KeyboardEvent) => {
      if (event.target instanceof HTMLInputElement) {
        return;
      }
      if (event.key === " " && !store.get(typeToShowInProgressAtom)) {
        event.preventDefault();
        this.playPause();
      }
      if (event.key === "ArrowRight") {
        event.preventDefault();
        this.next();
      }
      if (event.key === "ArrowLeft") {
        event.preventDefault();
        this.prev();
      }
    });
  }

  async reset() {
    this.audioRef = undefined;
    this.displayedPlaylistId = undefined;
    this.displayedTracks = [];
    this.playingPlaylistId = undefined;
    this.sortedPlayingTracks = [];
    this.playingTracks = [];
    this.playNextTracks = [];
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
        currentTime >= this.playingTrack.track.finish ||
        currentTime >= this.playingTrack.track.duration
      ) {
        this.trackFinished();
      }
    };
  }

  trackInfoUpdated(track: Track) {
    if (this.playingTrack?.track.id === track.id) {
      this.playingTrack.track = track;
      store.set(playingTrackAtom, this.playingTrack);

      if (
        this.stopped &&
        this.audioRef &&
        !store.get(waitingForMusicDownloadAtom)
      ) {
        this.audioRef.currentTime = this.playingTrack.track.start;
      }
    }
  }

  private async trackFinished() {
    if (!this.playingTrack) {
      return;
    }
    // make sure two ontimeupdate events don't trigger two next() calls
    if (this.addingPlay === this.playingTrack.track.id) {
      return;
    }

    this.addingPlay = this.playingTrack.track.id;
    try {
      this.audioRef!.pause();
      updatePersister().addPlay(this.playingTrack.track.id);
      // always get the latest version of the track just in case it was updated
      const track = await library().getTrack(this.playingTrack.track.id);
      if (track) {
        if (library().getTrackUserChanges()) {
          track.playCount++;
          await library().putTrack(track);
          store.get(trackUpdatedFnAtom).fn(track);
        }
        this.playingTrack.track = track;
        store.set(playingTrackAtom, this.playingTrack);
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
    displayedTracks: DisplayedTrack[]
  ) {
    if (
      displayedPlaylistId === this.displayedPlaylistId &&
      isEqual(this.displayedTracks, displayedTracks)
    ) {
      return;
    }

    this.displayedPlaylistId = displayedPlaylistId;
    this.displayedTracks = displayedTracks;
    if (this.stopped || this.displayedPlaylistId === this.playingPlaylistId) {
      this.rebuildPlayingTracks();
    }
  }

  async rebuildPlayingTracks(
    overwritePlayingTrack: DisplayedTrack | undefined = undefined
  ) {
    this.playingPlaylistId = this.displayedPlaylistId;
    this.sortedPlayingTracks = [...this.displayedTracks];
    await this.shuffleChanged(overwritePlayingTrack);
  }

  async shuffleChanged(
    overwritePlayingTrack: DisplayedTrack | undefined = undefined
  ) {
    const savedPlaying = this.playingTracks[this.playingTrackIdx];
    this.playingTracks = [...this.sortedPlayingTracks];
    if (store.get(shuffleAtom)) {
      this.playingTracks = shuffle(this.playingTracks);
    }

    if (overwritePlayingTrack) {
      this.playingTrackIdx = this.playingTracks.findIndex((dt) =>
        isEqual(dt, overwritePlayingTrack)
      );
      await this.updatePlayingTrack();
    } else if (this.stopped) {
      this.playingTrackIdx = 0;
      await this.updatePlayingTrack();
    } else {
      this.playingTrackIdx = this.playingTracks.findIndex((dt) =>
        isEqual(dt, savedPlaying)
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
    if (!this.audioRef || this.playingTracks.length === 0) {
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
      this.playNextTracks.shift();
      this.inPlayNextList = false;
      await this.updatePlayingTrack();
    } else if (this.shouldRewind()) {
      this.audioRef.currentTime = this.playingTrack.start;
      this.audioPlay();
    } else {
      this.playingTrackIdx =
        this.playingTrackIdx === 0
          ? this.playingTracks.length - 1
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
      this.playNextTracks.shift();
    }
    this.inPlayNextList = this.playNextTracks.length > 0;

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
        (this.playingTrackIdx + 1) % this.playingTracks.length;
      await this.updatePlayingTrack();
    }
    this.showPlayingTrackIfInPlaylist();
  }

  // actions
  async playTrack(track: DisplayedTrack) {
    this.inPlayNextList = false;
    this.playNextTracks = [];
    this.playingTracks = [];
    await this.rebuildPlayingTracks(track);
    this.play();
  }

  async playTrackNext(playlistTrack: PlaylistTrack) {
    if (this.inPlayNextList) {
      // add after the current play next track
      this.playNextTracks.splice(1, 0, playlistTrack);
    } else {
      this.playNextTracks.unshift(playlistTrack);
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
      fileId: track.musicFilename,
    };

    const url = await files().tryGetFileURL(
      FileType.MUSIC,
      track.musicFilename
    );
    if (url) {
      const a = document.createElement("a");
      a.href = url;
      a.download = `${track.artistName} - ${track.name}.${track.musicFilename.split(".")[-1]}`;
      a.click();
      this.pendingDownloads.delete(ids);
      setTimeout(() => {
        URL.revokeObjectURL(url);
      }, 1000);
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
    if (data.ids.fileId === this.playingTrack?.track.musicFilename) {
      this.trySetPlayingMusicFile();
    }
    if (this.pendingDownloads.has(data.ids)) {
      this.downloadMusic(data.ids.trackId);
    }
  }

  private handleArtworkFetched(data: FileFetchedMessage) {
    if (
      this.playingTrack &&
      this.playingTrack.track.artworkFilename === data.ids.fileId
    ) {
      this.trySetMediaMetadata();
    }
  }

  private async trySetPlayingMusicFile() {
    if (
      !this.playingTrack ||
      !this.audioRef ||
      this.lastSetAudioSrcTrackId === this.playingTrack.track.id
    ) {
      return;
    }

    const url = await files().tryGetFileURL(
      FileType.MUSIC,
      this.playingTrack.track.musicFilename
    );
    if (url) {
      store.set(waitingForMusicDownloadAtom, false);
      const oldUrl = this.audioRef.src;
      this.audioRef.src = url;
      this.audioRef.currentTime = this.playingTrack.track.start;
      this.lastSetAudioSrcTrackId = this.playingTrack.track.id;
      if (this.playing) {
        this.audioPlay();
      }
      if (oldUrl) {
        URL.revokeObjectURL(oldUrl);
      }
    } else {
      store.set(waitingForMusicDownloadAtom, true);
      this.audioRef.pause();
    }
  }

  private audioPlay() {
    if (this.lastSetAudioSrcTrackId !== this.playingTrack?.track.id) {
      return;
    }
    this.audioRef?.play().catch(() => {
      // nop, this happens when the user pauses the audio
    });
  }

  private shouldRewind() {
    return store.get(repeatAtom) || this.playingTracks.length === 1;
  }

  private inValidState(): this is {
    audioRef: HTMLAudioElement;
    playingTrack: Track;
    playingTrackIds: string[];
  } {
    return (
      this.audioRef !== undefined &&
      this.playingTrack !== undefined &&
      this.playingTracks.length > 0
    );
  }

  private async updatePlayingTrack() {
    if (this.playingTracks.length === 0 && this.playNextTracks.length === 0) {
      return;
    }

    if (this.inPlayNextList) {
      const playNextTrack = this.playNextTracks[0];
      const track = await library().getTrack(playNextTrack.trackId);
      this.playingTrack = {
        track: track!,
        playlistId: playNextTrack.playlistId,
        playlistOffset: playNextTrack.playlistOffset,
      };
    } else {
      const displayedTrack = this.playingTracks[this.playingTrackIdx];
      const track = await library().getTrack(displayedTrack.trackId);
      this.playingTrack = {
        track: track!,
        playlistId: this.playingPlaylistId!,
        playlistOffset: displayedTrack.playlistOffset,
      };
    }

    store.set(playingTrackAtom, this.playingTrack);
    store.set(currentTimeAtom, this.playingTrack!.track.start);
    this.trySetMediaMetadata();
    this.trySetPlayingMusicFile();
    await this.preloadTracks();
  }

  private async trySetMediaMetadata() {
    if (!navigator.mediaSession || !this.playingTrack) {
      return;
    }

    const metadata = new MediaMetadata({
      title: this.playingTrack.track.name,
      artist: this.playingTrack.track.artistName,
      album: this.playingTrack.track.albumName,
      artwork: [],
    });

    // NB: media metadata artwork not working in Firefox but does in Chrome
    const url = this.playingTrack.track.artworkFilename
      ? await files().tryGetFileURL(
          FileType.ARTWORK,
          this.playingTrack.track.artworkFilename
        )
      : null;
    if (url) {
      const ext = this.playingTrack.track.artworkFilename!.split(".").pop();
      const mime = ext ? IMAGE_EXTENSION_TO_MIME.get(ext) : null;
      if (mime) {
        metadata.artwork = [{ src: url, type: mime }];
      }
    }

    const oldUrl = navigator.mediaSession.metadata?.artwork[0]?.src;
    navigator.mediaSession.metadata = metadata;

    if (oldUrl) {
      URL.revokeObjectURL(oldUrl);
    }
  }

  private async preloadTracks() {
    const displayedTracks = circularArraySlice(
      this.playingTracks,
      this.playingTrackIdx,
      TRACKS_TO_PRELOAD
    );
    const trackIds = [
      ...displayedTracks.map((dt) => dt.trackId),
      ...this.playNextTracks.map((pt) => pt.trackId),
    ];

    const musicIds: TrackFileIds[] = [];
    const artworkIds: TrackFileIds[] = [];
    for (const trackId of trackIds) {
      const track = await library().getTrack(trackId);
      if (track) {
        musicIds.push({ trackId: track.id, fileId: track.musicFilename });
        if (track.artworkFilename) {
          artworkIds.push({ trackId: track.id, fileId: track.artworkFilename });
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
    if (
      this.playingTrack &&
      this.playingTrack.playlistId === this.displayedPlaylistId
    ) {
      store.get(showTrackFnAtom).fn({
        playlistId: this.playingTrack.playlistId,
        playlistOffset: this.playingTrack.playlistOffset,
      });
    }
  }
}

export const player = memoize(() => new Player());
