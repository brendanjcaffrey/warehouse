import { shuffle as lodashShuffle } from "lodash";
import { PlaylistTrack } from "./Types";
import { circularArraySlice } from "./Util";

// the now playing queue: an ordered list of tracks with a current position. it
// is a snapshot - once built from a view it never changes on its own, only
// through the explicit calls here (advance, play next, shuffle). entries and
// context share the same objects, so tracks are matched by reference identity,
// which keeps duplicates (the same track twice in a playlist) distinct
export class PlayQueue {
  // the queue in play order
  private entries: PlaylistTrack[];
  // the original order, kept so turning shuffle off can restore it
  private context: PlaylistTrack[];
  // the position of the current track within entries
  private index: number;
  private shuffled: boolean;

  // context defaults to entries; pass it explicitly when entries is already a
  // shuffled ordering of an original list so un-shuffle can get back to it
  constructor(
    entries: PlaylistTrack[] = [],
    startIndex = 0,
    shuffled = false,
    context?: PlaylistTrack[]
  ) {
    this.entries = [...entries];
    this.context = context ? [...context] : [...entries];
    this.index = entries.length
      ? Math.min(Math.max(0, startIndex), entries.length - 1)
      : 0;
    this.shuffled = shuffled;
  }

  get current(): PlaylistTrack | undefined {
    return this.entries[this.index];
  }

  get length(): number {
    return this.entries.length;
  }

  get isEmpty(): boolean {
    return this.entries.length === 0;
  }

  // the next `count` entries starting at the current one, wrapping around; used
  // to preload upcoming tracks
  slice(count: number): PlaylistTrack[] {
    return circularArraySlice(this.entries, this.index, count);
  }

  // steps to the next track, wrapping around from the last back to the first
  // when asked; returns whether the position moved
  advance(wrapping = true): boolean {
    if (this.isEmpty) {
      return false;
    }
    if (this.index + 1 < this.entries.length) {
      this.index++;
      return true;
    }
    if (wrapping) {
      this.index = 0;
      return true;
    }
    return false;
  }

  // steps back one position, wrapping around from the first to the last track
  // when asked; returns whether the position moved
  goBack(wrapping = true): boolean {
    if (this.isEmpty) {
      return false;
    }
    if (this.index > 0) {
      this.index--;
      return true;
    }
    if (wrapping) {
      this.index = this.entries.length - 1;
      return true;
    }
    return false;
  }

  // inserts a track right after the current one so it plays next but still sits
  // in the queue; it joins the context too so it survives an un-shuffle. with an
  // empty queue it just becomes the whole queue
  playNext(entry: PlaylistTrack) {
    if (this.isEmpty) {
      this.entries = [entry];
      this.context = [entry];
      this.index = 0;
      return;
    }
    const current = this.entries[this.index];
    this.entries.splice(this.index + 1, 0, entry);
    const contextPos = this.context.indexOf(current);
    if (contextPos >= 0) {
      this.context.splice(contextPos + 1, 0, entry);
    } else {
      this.context.push(entry);
    }
  }

  // shuffles the upcoming tracks, or restores the original order and continues
  // from wherever the current track sits in it. the current track never moves
  setShuffled(shuffled: boolean) {
    if (shuffled === this.shuffled) {
      return;
    }
    this.shuffled = shuffled;
    const current = this.current;
    if (shuffled) {
      if (this.index + 1 >= this.entries.length) {
        return;
      }
      const head = this.entries.slice(0, this.index + 1);
      const tail = lodashShuffle(this.entries.slice(this.index + 1));
      this.entries = [...head, ...tail];
    } else {
      this.entries = [...this.context];
      const pos = current ? this.entries.indexOf(current) : -1;
      this.index = pos >= 0 ? pos : 0;
    }
  }
}
