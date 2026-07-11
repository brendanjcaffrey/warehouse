import { atom, createStore } from "jotai";
import { Track } from "./Library";
import { PlayingTrack } from "./Types";

export const store = createStore();

export const clearAuthFnAtom = atom({ fn: () => {} });
export const clearSettingsFnAtom = atom({ fn: () => {} });
export const trackUpdatedFnAtom = atom({ fn: (_: Track) => {} }); // eslint-disable-line @typescript-eslint/no-unused-vars

// the most recently edited track, so the track lists can patch their loaded
// copy in place when a rating or edit lands without a full reload
export const updatedTrackAtom = atom<Track | null>(null);

export const searchAtom = atom("");
export const anyDownloadErrorsAtom = atom(false);
export const typeToShowInProgressAtom = atom(false);

// which view a "go to" from the track menu is heading for; songs and playlist
// both render TrackList so they're told apart by the id
export type RevealView = "songs" | "artists" | "albums" | "playlist";

// a one-shot request to reveal a track in another view: the destination view
// selects the right artist/album/playlist, scrolls to the track and highlights
// it, then clears this so it fires once. selectionId is the artist name, album
// key or playlist id the destination needs to select (unused for songs)
export interface RevealTarget {
  trackId: string;
  view: RevealView;
  selectionId?: string;
}

export const revealTargetAtom = atom<RevealTarget | null>(null);

export const stoppedAtom = atom(true);
export const playingAtom = atom(false);
export const waitingForMusicDownloadAtom = atom(false);
export const playingTrackAtom = atom<PlayingTrack | undefined>(undefined);
export const currentTimeAtom = atom(0);

export async function resetAllState() {
  store.set(clearAuthFnAtom, { fn: () => {} });
  store.set(clearSettingsFnAtom, { fn: () => {} });
  store.set(trackUpdatedFnAtom, { fn: (_: Track) => {} }); // eslint-disable-line @typescript-eslint/no-unused-vars

  store.set(updatedTrackAtom, null);
  store.set(searchAtom, "");
  store.set(anyDownloadErrorsAtom, false);
  store.set(revealTargetAtom, null);

  store.set(stoppedAtom, true);
  store.set(playingAtom, false);
  store.set(playingTrackAtom, undefined);
  store.set(currentTimeAtom, 0);
}
