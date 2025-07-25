import { atom, createStore } from "jotai";
import { Track } from "./Library";
import { PlayingTrack, PlaylistEntry } from "./Types";

export const store = createStore();

export const clearAuthFnAtom = atom({ fn: () => {} });
export const clearSettingsFnAtom = atom({ fn: () => {} });
export const trackUpdatedFnAtom = atom({ fn: (_: Track) => {} }); // eslint-disable-line @typescript-eslint/no-unused-vars
export const showTrackFnAtom = atom({ fn: (_: PlaylistEntry) => {} }); // eslint-disable-line @typescript-eslint/no-unused-vars

export const selectedPlaylistIdAtom = atom("");
export const searchAtom = atom("");
export const anyDownloadErrorsAtom = atom(false);
export const typeToShowInProgressAtom = atom(false);

export const stoppedAtom = atom(true);
export const playingAtom = atom(false);
export const waitingForMusicDownloadAtom = atom(false);
export const playingTrackAtom = atom<PlayingTrack | undefined>(undefined);
export const currentTimeAtom = atom(0);

export async function resetAllState() {
  store.set(clearAuthFnAtom, { fn: () => {} });
  store.set(clearSettingsFnAtom, { fn: () => {} });
  store.set(trackUpdatedFnAtom, { fn: (_: Track) => {} }); // eslint-disable-line @typescript-eslint/no-unused-vars
  store.set(showTrackFnAtom, { fn: (_: PlaylistEntry) => {} }); // eslint-disable-line @typescript-eslint/no-unused-vars

  store.set(selectedPlaylistIdAtom, "");
  store.set(searchAtom, "");
  store.set(anyDownloadErrorsAtom, false);

  store.set(stoppedAtom, true);
  store.set(playingAtom, false);
  store.set(playingTrackAtom, undefined);
  store.set(currentTimeAtom, 0);
}
