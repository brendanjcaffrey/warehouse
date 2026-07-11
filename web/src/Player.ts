import { memoize, shuffle as lodashShuffle } from "lodash";
import { volumeAtom, shuffleAtom, repeatAtom } from "./Settings";
import {
  store,
  trackUpdatedFnAtom,
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
import { TrackFileSet } from "./TrackFileSet";
import { PlayingTrack, PlaylistTrack } from "./Types";
import { PlayQueue } from "./PlayQueue";
import { trackFinish, shouldSkipAtFinish } from "./PlaybackFinish";
import { IMAGE_EXTENSION_TO_MIME } from "./MimeTypes";

const TRACKS_TO_PRELOAD = 3;
// how far into a track the previous button restarts it instead of stepping back
const PREV_RESTART_SECONDS = 3;

class Player {
  audioRef: HTMLAudioElement | undefined = undefined;

  // the now playing queue. it is a snapshot set only by the direct user actions
  // below (play, play shuffled, play next) - navigating, filtering or re-sorting
  // a view never touches it, so a filtered view keeps playing even once the
  // filter is cleared
  queue: PlayQueue = new PlayQueue();
  playingTrack: PlayingTrack | undefined = undefined;
  // last track we set the audio src to, here to avoid setting it to the same thing
  lastSetAudioSrcTrackId: string | undefined = undefined;

  // stopped is true at load, then false forever after the first track is played
  stopped: boolean = true;
  // whether actively playing or paused
  playing: boolean = false;
  // set when the user seeks at or past the finish point, letting the current
  // track play through to its real end rather than skipping at the trim finish
  playedPastFinish: boolean = false;

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
    this.queue = new PlayQueue();
    this.playingTrack = undefined;
    this.lastSetAudioSrcTrackId = undefined;
    this.stopped = true;
    this.playing = false;
    this.playedPastFinish = false;
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

      if (!this.playingTrack || !this.audioSettledOnPlayingTrack()) {
        return;
      }
      const track = this.playingTrack.track;
      if (
        shouldSkipAtFinish(
          currentTime,
          track.start,
          trackFinish(track),
          this.playedPastFinish
        )
      ) {
        this.trackFinished();
      }
    };
  }

  // true only once the audio element has settled on the currently playing
  // track's source - src matches, not mid-seek, and has data at the current
  // position. guards finish-detection against stale readings while a new track
  // is still loading/seeking.
  private audioSettledOnPlayingTrack(): boolean {
    return (
      this.audioRef !== undefined &&
      this.playingTrack !== undefined &&
      this.lastSetAudioSrcTrackId === this.playingTrack.track.id &&
      !this.audioRef.seeking &&
      this.audioRef.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA
    );
  }

  trackUpdated(track: Track) {
    if (this.playingTrack?.track.id === track.id) {
      this.playingTrack.track = track;
      store.set(playingTrackAtom, { ...this.playingTrack });

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
        store.set(playingTrackAtom, { ...this.playingTrack });
      }
      await this.advanceAfterFinish();
    } finally {
      this.addingPlay = undefined;
    }
  }

  // moves on when a track plays through to the end, honouring the repeat mode:
  // repeat one replays it, repeat all loops the queue, off stops at the end
  private async advanceAfterFinish() {
    const mode = store.get(repeatAtom);
    if (mode === "one") {
      this.audioRef!.currentTime = this.playingTrack!.track.start;
      this.audioPlay();
      return;
    }
    if (this.queue.advance(mode === "all")) {
      await this.updatePlayingTrack();
    } else {
      this.stop();
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
    if (this.playingTrack) {
      // a seek at or past the finish lets the track play out to its real end;
      // seeking back before it restores the normal finish cutoff
      this.playedPastFinish = time >= trackFinish(this.playingTrack.track);
    }
    store.set(currentTimeAtom, time);
  }

  // actions - the only things that change the queue

  // plays a list of tracks starting at the tapped one, so previous walks back
  // through the earlier tracks. replaces the queue with a snapshot of the list.
  // when shuffle is on the tapped track leads and the rest follow in random order
  async playTracks(playlistId: string, tracks: Track[], startIndex: number) {
    const entries = this.toEntries(playlistId, tracks);
    if (entries.length === 0) {
      return;
    }
    if (store.get(shuffleAtom)) {
      const lead = entries[startIndex];
      const rest = lodashShuffle(entries.filter((_, i) => i !== startIndex));
      this.queue = new PlayQueue([lead, ...rest], 0, true, entries);
    } else {
      this.queue = new PlayQueue(entries, startIndex, false);
    }
    await this.startQueue();
  }

  // plays a list of tracks in order and turns shuffle off, the counterpart to
  // playTracksShuffled for an explicit play button
  async playTracksInOrder(
    playlistId: string,
    tracks: Track[],
    startIndex: number
  ) {
    store.set(shuffleAtom, false);
    await this.playTracks(playlistId, tracks, startIndex);
  }

  // plays a list of tracks in a random order and turns shuffle on
  async playTracksShuffled(playlistId: string, tracks: Track[]) {
    const entries = this.toEntries(playlistId, tracks);
    if (entries.length === 0) {
      return;
    }
    store.set(shuffleAtom, true);
    this.queue = new PlayQueue(lodashShuffle(entries), 0, true, entries);
    await this.startQueue();
  }

  // queues a track right after the current one, or just plays it when nothing
  // is queued yet
  async playTrackNext(playlistId: string, track: Track) {
    const wasEmpty = this.queue.isEmpty;
    this.queue.playNext({ playlistId, trackId: track.id, playlistOffset: -1 });
    if (wasEmpty) {
      await this.startQueue();
    } else {
      await this.preloadTracks();
    }
  }

  private toEntries(playlistId: string, tracks: Track[]): PlaylistTrack[] {
    return tracks.map((track, i) => ({
      playlistId,
      trackId: track.id,
      playlistOffset: i,
    }));
  }

  private async startQueue() {
    await this.updatePlayingTrack();
    this.play();
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
    if (!this.audioRef || this.queue.isEmpty) {
      return;
    }

    if (!this.playing) {
      // resuming after playback stopped at the end of the last track restarts
      // it from the top rather than sitting finished
      if (this.playingTrack && this.atTrackEnd()) {
        this.setCurrentTime(this.playingTrack.track.start);
      }
      this.trySetPlayingMusicFile();
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

  // whether the audio has played through to the current track's finish
  private atTrackEnd(): boolean {
    if (!this.audioRef || !this.playingTrack) {
      return false;
    }
    return this.audioRef.currentTime >= trackFinish(this.playingTrack.track);
  }

  async prev() {
    if (!this.inValidState()) {
      return;
    }

    // restart the current track when we're more than a moment into it,
    // otherwise step back to the previous one (wrapping round at the start)
    const intoTrack = this.audioRef.currentTime - this.playingTrack.track.start;
    if (intoTrack > PREV_RESTART_SECONDS) {
      this.audioRef.currentTime = this.playingTrack.track.start;
      this.audioPlay();
    } else if (this.queue.goBack(store.get(repeatAtom) === "all")) {
      // repeat all wraps from the first track back to the last; otherwise stay
      // put on the first track rather than wrapping around
      await this.updatePlayingTrack();
    }
  }

  async next() {
    if (!this.inValidState()) {
      return;
    }

    // repeat all loops the queue; otherwise stop once past the last track
    if (this.queue.advance(store.get(repeatAtom) === "all")) {
      await this.updatePlayingTrack();
    } else {
      this.stop();
    }
  }

  // halts playback at the end of the queue, leaving the last track showing
  private stop() {
    this.audioRef?.pause();
    this.playing = false;
    store.set(playingAtom, false);
  }

  // reshuffles the upcoming tracks or restores their order without disturbing
  // the current track
  setShuffled(shuffled: boolean) {
    this.queue.setShuffled(shuffled);
    this.preloadTracks();
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

  private inValidState(): this is {
    audioRef: HTMLAudioElement;
    playingTrack: PlayingTrack;
  } {
    return (
      this.audioRef !== undefined &&
      this.playingTrack !== undefined &&
      !this.queue.isEmpty
    );
  }

  private async updatePlayingTrack() {
    const entry = this.queue.current;
    if (!entry) {
      return;
    }

    const track = await library().getTrack(entry.trackId);
    if (!track) {
      return;
    }
    this.playingTrack = {
      track,
      playlistId: entry.playlistId,
      playlistOffset: entry.playlistOffset,
    };
    // a fresh track starts under the normal finish cutoff again
    this.playedPastFinish = false;

    store.set(playingTrackAtom, this.playingTrack);
    store.set(currentTimeAtom, track.start);
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
    const preloadTracks = this.queue.slice(TRACKS_TO_PRELOAD);
    const trackIds = preloadTracks.map((pt) => pt.trackId);

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
}

export const player = memoize(() => new Player());
