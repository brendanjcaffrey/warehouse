import { atom, createStore } from "jotai";
import { Track } from "./Library";

export const store = createStore();

export const clearAuthFnAtom = atom({ fn: () => {} });
export const clearSettingsFnAtom = atom({ fn: () => {} });
export const clearFilesFnAtom = atom({ fn: () => {} }); // TODO

export const selectedPlaylistIdAtom = atom("");
export const searchAtom = atom("");

export const stoppedAtom = atom(true);
export const playingAtom = atom(false);
export const playingTrackAtom = atom<Track | undefined>(undefined);
export const currentTimeAtom = atom(0);
