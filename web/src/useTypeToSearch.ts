import { KeyboardEvent, useCallback, useEffect, useRef } from "react";
import { store, typeToShowInProgressAtom } from "./State";

// the accumulated query resets after this long without a keystroke
const RESET_MS = 700;

// finds the index of the nearest item to the typed query: a prefix match wins,
// otherwise the first item that contains it
export function nearestMatch(items: string[], query: string): number {
  if (!query) {
    return -1;
  }
  let contains = -1;
  for (let i = 0; i < items.length; i++) {
    const value = items[i].toLowerCase();
    if (value.startsWith(query)) {
      return i;
    }
    if (contains === -1 && value.includes(query)) {
      contains = i;
    }
  }
  return contains;
}

// which keystrokes extend the query: single printable characters without
// modifiers. a bare space is the play/pause shortcut rather than a query
// character, so it only counts once a query is already under way (letting
// multi-word matches like "led zeppelin" still work)
export function isQueryKey(
  key: string,
  hasQuery: boolean,
  modifiers: { metaKey: boolean; ctrlKey: boolean; altKey: boolean }
): boolean {
  if (
    key.length !== 1 ||
    modifiers.metaKey ||
    modifiers.ctrlKey ||
    modifiers.altKey
  ) {
    return false;
  }
  return key !== " " || hasQuery;
}

// type-to-search for a focused list: printable keys accumulate into a query
// (cleared after a pause) and each keystroke reports the nearest match, so
// typing "led" scrolls to "led zeppelin". returns true when it handled the key.
// while a query is under way it flags typeToShowInProgressAtom so the player's
// global space shortcut steps aside and the space lands in the query instead
export function useTypeToSearch(
  items: string[],
  onMatch: (index: number) => void
) {
  const bufferRef = useRef("");
  const timerRef = useRef<number | null>(null);

  const clear = useCallback(() => {
    if (timerRef.current !== null) {
      window.clearTimeout(timerRef.current);
      timerRef.current = null;
    }
    bufferRef.current = "";
    store.set(typeToShowInProgressAtom, false);
  }, []);

  // a query left in progress when the list unmounts would keep space captured
  useEffect(() => clear, [clear]);

  return useCallback(
    (event: KeyboardEvent): boolean => {
      const key = event.key;
      if (!isQueryKey(key, bufferRef.current !== "", event)) {
        return false;
      }
      bufferRef.current += key.toLowerCase();
      store.set(typeToShowInProgressAtom, true);
      if (timerRef.current !== null) {
        window.clearTimeout(timerRef.current);
      }
      timerRef.current = window.setTimeout(clear, RESET_MS);

      const index = nearestMatch(items, bufferRef.current);
      if (index >= 0) {
        onMatch(index);
      }
      return true;
    },
    [items, onMatch, clear]
  );
}
