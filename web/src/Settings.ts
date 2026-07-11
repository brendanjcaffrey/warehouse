import { atomWithStorage } from "jotai/utils";

const KEEP_MODE_KEY = "keepMode";
const DOWNLOAD_MODE_KEY = "downloadMode";
const SHUFFLE_KEY = "shuffle";
const REPEAT_KEY = "repeat";
const SHOW_ARTWORK_KEY = "showArtwork";
const VOLUME_KEY = "volume";
const OPENED_FOLDERS_KEY = "openedFolders";
const SIDEBAR_WIDTH_KEY = "sidebarWidth";
const ARTIST_LIST_WIDTH_KEY = "artistListWidth";
const ALBUM_LIST_WIDTH_KEY = "albumListWidth";

export const DEFAULT_VOLUME = 50;
export const DEFAULT_SIDEBAR_WIDTH = 260;
export const SIDEBAR_MIN_WIDTH = 180;
export const SIDEBAR_MAX_WIDTH = 480;

export function ClampSidebarWidth(value: number): number {
  return Math.min(SIDEBAR_MAX_WIDTH, Math.max(SIDEBAR_MIN_WIDTH, value));
}

// read the persisted value synchronously at init so we don't flash a default
// before hydrating from local storage
const options = { getOnInit: true } as const;

// a set of strings persisted as a json array
export const stringSetStorage = {
  getItem(key: string, initialValue: Set<string>): Set<string> {
    const value = localStorage.getItem(key);
    if (value === null) {
      return initialValue;
    }
    try {
      const parsed = JSON.parse(value);
      if (Array.isArray(parsed)) {
        return new Set(parsed as string[]);
      }
      return initialValue;
    } catch {
      return initialValue;
    }
  },
  setItem(key: string, value: Set<string>): void {
    localStorage.setItem(key, JSON.stringify(Array.from(value)));
  },
  removeItem(key: string): void {
    localStorage.removeItem(key);
  },
};

// a width clamped to the allowed range on the way in
const sidebarWidthStorage = {
  getItem(key: string, initialValue: number): number {
    const value = localStorage.getItem(key);
    if (value === null) {
      return initialValue;
    }
    const parsed = Number(value);
    if (Number.isNaN(parsed)) {
      return initialValue;
    }
    return ClampSidebarWidth(parsed);
  },
  setItem(key: string, value: number): void {
    localStorage.setItem(key, value.toString());
  },
  removeItem(key: string): void {
    localStorage.removeItem(key);
  },
};

export const keepModeAtom = atomWithStorage(
  KEEP_MODE_KEY,
  false,
  undefined,
  options
);
export const downloadModeAtom = atomWithStorage(
  DOWNLOAD_MODE_KEY,
  false,
  undefined,
  options
);
export const shuffleAtom = atomWithStorage(
  SHUFFLE_KEY,
  false,
  undefined,
  options
);
export const repeatAtom = atomWithStorage(
  REPEAT_KEY,
  false,
  undefined,
  options
);
export const showArtworkAtom = atomWithStorage(
  SHOW_ARTWORK_KEY,
  false,
  undefined,
  options
);
export const volumeAtom = atomWithStorage(
  VOLUME_KEY,
  DEFAULT_VOLUME,
  undefined,
  options
);
export const openedFoldersAtom = atomWithStorage(
  OPENED_FOLDERS_KEY,
  new Set<string>(),
  stringSetStorage,
  options
);
export const sidebarWidthAtom = atomWithStorage(
  SIDEBAR_WIDTH_KEY,
  DEFAULT_SIDEBAR_WIDTH,
  sidebarWidthStorage,
  options
);
// the artists list on the left of the artists view reuses the sidebar's width
// bounds and clamping storage
export const artistListWidthAtom = atomWithStorage(
  ARTIST_LIST_WIDTH_KEY,
  DEFAULT_SIDEBAR_WIDTH,
  sidebarWidthStorage,
  options
);
// the album list on the left of the albums view reuses the same width bounds
export const albumListWidthAtom = atomWithStorage(
  ALBUM_LIST_WIDTH_KEY,
  DEFAULT_SIDEBAR_WIDTH,
  sidebarWidthStorage,
  options
);
