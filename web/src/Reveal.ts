import { RefObject, useEffect } from "react";
import { useAtom, useAtomValue } from "jotai";
import { Track } from "./Library";
import { RevealTarget, RevealView, revealTargetAtom } from "./State";

// which row a "go to" targets in a parent list view (artists/albums): the
// selection to make and the index to scroll to, -1 when the row isn't present
// yet. null when the reveal isn't for this view or carries no selection
export function revealListSelection(
  reveal: RevealTarget | null,
  view: RevealView,
  selectionIds: string[]
): { selectionId: string; index: number } | null {
  if (!reveal || reveal.view !== view || !reveal.selectionId) {
    return null;
  }
  return {
    selectionId: reveal.selectionId,
    index: selectionIds.indexOf(reveal.selectionId),
  };
}

// whether a track-list view owns a reveal. the songs view owns "go to song"
// (view "songs"); a playlist owns a "show in playlist" whose id matches it
export function trackListOwnsReveal(
  reveal: RevealTarget | null,
  playlistId: string | undefined
): boolean {
  if (!reveal) {
    return false;
  }
  return playlistId
    ? reveal.view === "playlist" && reveal.selectionId === playlistId
    : reveal.view === "songs";
}

// a parent list view (artists/albums) consuming a "go to": select the target
// and scroll its row into view. it does not clear the reveal; the detail view
// that mounts underneath reveals the track and clears it
export function useRevealListSelection(
  view: RevealView,
  selectionIds: string[],
  selected: string | null,
  onSelect: (selectionId: string) => void,
  scrollToIndex: (index: number) => void
) {
  const reveal = useAtomValue(revealTargetAtom);
  useEffect(() => {
    const match = revealListSelection(reveal, view, selectionIds);
    if (!match) {
      return;
    }
    if (selected !== match.selectionId) {
      onSelect(match.selectionId);
    }
    if (match.index !== -1) {
      scrollToIndex(match.index);
    }
  }, [reveal, view, selectionIds, selected, onSelect, scrollToIndex]);
}

// a track-list view (songs/playlist) consuming a "go to song" or "show in
// playlist": once its tracks have loaded it selects and centres the track, then
// clears the reveal whether or not the track was present so it can't linger
export function useTrackListReveal(
  playlistId: string | undefined,
  loaded: boolean,
  rows: Track[],
  onReveal: (trackId: string, index: number) => void
) {
  const [reveal, setReveal] = useAtom(revealTargetAtom);
  useEffect(() => {
    if (!reveal || !trackListOwnsReveal(reveal, playlistId) || !loaded) {
      return;
    }
    const index = rows.findIndex((track) => track.id === reveal.trackId);
    if (index !== -1) {
      onReveal(reveal.trackId, index);
    }
    setReveal(null);
  }, [reveal, playlistId, loaded, rows, onReveal, setReveal]);
}

// a detail track view (artist/album) consuming a "go to": when the target track
// is among its tracks, select it, scroll it to the middle by its data-track-id
// and clear the reveal. the parent list has already selected the right
// artist/album, so the track is in flatTracks once this view mounts
export function useDetailTrackReveal(
  view: RevealView,
  flatTracks: Track[],
  containerRef: RefObject<HTMLElement | null>,
  onSelect: (trackId: string) => void
) {
  const [reveal, setReveal] = useAtom(revealTargetAtom);
  useEffect(() => {
    if (!reveal || reveal.view !== view) {
      return;
    }
    if (!flatTracks.some((track) => track.id === reveal.trackId)) {
      return;
    }
    onSelect(reveal.trackId);
    containerRef.current
      ?.querySelector(`[data-track-id="${CSS.escape(reveal.trackId)}"]`)
      ?.scrollIntoView({ block: "center" });
    setReveal(null);
  }, [reveal, view, flatTracks, containerRef, onSelect, setReveal]);
}
