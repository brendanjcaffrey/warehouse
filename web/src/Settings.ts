import { atom } from "jotai";

const KEEP_MODE_KEY = "keepMode";
const DOWNLOAD_MODE_KEY = "downloadMode";
const SHUFFLE_KEY = "shuffle";
const REPEAT_KEY = "repeat";
const SHOW_ARTWORK_KEY = "showArtwork";
const VOLUME_KEY = "volume";
const OPENED_FOLDERS_KEY = "openedFolders";

export const DEFAULT_VOLUME = 50;

function GetPersistedKeepMode(): boolean {
  const value = localStorage.getItem(KEEP_MODE_KEY);
  if (value === null) {
    return false;
  } else {
    return value === "true";
  }
}

export function SetPersistedKeepMode(value: boolean) {
  localStorage.setItem(KEEP_MODE_KEY, value.toString());
}

function GetPersistedDownloadMode(): boolean {
  const value = localStorage.getItem(DOWNLOAD_MODE_KEY);
  if (value === null) {
    return false;
  } else {
    return value === "true";
  }
}

export function SetPersistedDownloadMode(value: boolean) {
  localStorage.setItem(DOWNLOAD_MODE_KEY, value.toString());
}

function GetPersistedShuffle(): boolean {
  return localStorage.getItem(SHUFFLE_KEY) === "true";
}

export function SetPersistedShuffle(value: boolean) {
  localStorage.setItem(SHUFFLE_KEY, value.toString());
}

function GetPersistedRepeat(): boolean {
  return localStorage.getItem(REPEAT_KEY) === "true";
}

export function SetPersistedRepeat(value: boolean) {
  localStorage.setItem(REPEAT_KEY, value.toString());
}

function GetPersistedShowArtwork(): boolean {
  return localStorage.getItem(SHOW_ARTWORK_KEY) === "true";
}

export function SetPersistedShowArtwork(value: boolean) {
  localStorage.setItem(SHOW_ARTWORK_KEY, value.toString());
}

function GetPersistedVolume(): number {
  try {
    const value = localStorage.getItem(VOLUME_KEY);
    if (value === null) {
      return DEFAULT_VOLUME;
    }
    return Number(value);
  } catch {
    return DEFAULT_VOLUME;
  }
}

export function SetPersistedVolume(value: number) {
  localStorage.setItem(VOLUME_KEY, value.toString());
}

function GetPersistedOpenedFolders(): Set<string> {
  return new Set((localStorage.getItem(OPENED_FOLDERS_KEY) || "").split(","));
}

export function SetPersistedOpenedFolders(value: Set<string>) {
  localStorage.setItem(OPENED_FOLDERS_KEY, Array.from(value).join(","));
}

export const keepModeAtom = atom(GetPersistedKeepMode());
export const downloadModeAtom = atom(GetPersistedDownloadMode());
export const shuffleAtom = atom(GetPersistedShuffle());
export const repeatAtom = atom(GetPersistedRepeat());
export const showArtworkAtom = atom(GetPersistedShowArtwork());
export const volumeAtom = atom(GetPersistedVolume());
export const openedFoldersAtom = atom(GetPersistedOpenedFolders());
