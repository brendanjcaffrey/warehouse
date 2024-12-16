import { atom } from "jotai";

export const clearAuthFnAtom = atom({ fn: () => {} });
export const clearSettingsFnAtom = atom({ fn: () => {} });
export const clearFilesFnAtom = atom({ fn: () => {} });
export const playingAtom = atom(false);
export const selectedPlaylistAtom = atom("");
