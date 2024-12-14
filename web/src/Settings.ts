import { atom } from "jotai";

const SHUFFLE_KEY = "shuffle";
const REPEAT_KEY = "repeat";
const VOLUME_KEY = "volume";

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

function GetPersistedVolume(): number {
  try {
    return Number(localStorage.getItem(VOLUME_KEY));
  } catch {
    return 50;
  }
}

export function SetPersistedVolume(value: number) {
  localStorage.setItem(VOLUME_KEY, value.toString());
}

export const shuffleAtom = atom(GetPersistedShuffle());
export const repeatAtom = atom(GetPersistedRepeat());
export const volumeAtom = atom(GetPersistedVolume());
