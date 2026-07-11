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
  // every track played, in the order it was played, even ones skipped partway
  // through or played more than once. kept apart from the earlier queue
  // positions because going back wraps and jumping around diverges from the
  // real play order, so this is the true history
  private playedHistory: PlaylistTrack[];

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
    this.playedHistory = [];
  }

  get current(): PlaylistTrack | undefined {
    return this.entries[this.index];
  }

  // the tracks already played, oldest first, so the most recent play sits
  // right before the current track in the queue view
  get history(): PlaylistTrack[] {
    return [...this.playedHistory];
  }

  // every track after the current one, in play order
  get upcoming(): PlaylistTrack[] {
    return this.index + 1 < this.entries.length
      ? this.entries.slice(this.index + 1)
      : [];
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

  // steps to the next track, recording the current one as played even when it
  // was skipped partway through; wraps around from the last back to the first
  // when asked. returns whether the position moved
  advance(wrapping = true): boolean {
    if (this.isEmpty) {
      return false;
    }
    if (this.index + 1 < this.entries.length) {
      this.recordCurrentPlayed();
      this.index++;
      return true;
    }
    if (wrapping) {
      this.recordCurrentPlayed();
      this.index = 0;
      return true;
    }
    return false;
  }

  // steps back one position, recording the current track as played and wrapping
  // around from the first to the last track when asked; returns whether the
  // position moved
  goBack(wrapping = true): boolean {
    if (this.isEmpty) {
      return false;
    }
    if (this.index > 0) {
      this.recordCurrentPlayed();
      this.index--;
      return true;
    }
    if (wrapping) {
      this.recordCurrentPlayed();
      this.index = this.entries.length - 1;
      return true;
    }
    return false;
  }

  // jumps ahead to an upcoming track picked in the queue view; only the current
  // track counts as played, the skipped tracks in between are dropped without
  // recording them. returns whether the position moved
  jumpToUpcoming(upcomingIndex: number): boolean {
    const target = this.index + 1 + upcomingIndex;
    if (this.isEmpty || upcomingIndex < 0 || target >= this.entries.length) {
      return false;
    }
    this.recordCurrentPlayed();
    this.index = target;
    return true;
  }

  // records the current track as played again without moving, for repeat one
  // replaying it at the end. returns whether there was a track to record
  recordCurrentPlayed(): boolean {
    const current = this.current;
    if (!current) {
      return false;
    }
    // a fresh copy so a track played twice stays a distinct history row and
    // never aliases a live queue entry that is matched by reference identity
    this.playedHistory.push({ ...current });
    return true;
  }

  // carries a prior queue's play history into this one when it replaces it; the
  // track that was playing counts as played since it was cut off partway
  inheritHistory(previous: PlayQueue) {
    const carried = previous.playedHistory.map((entry) => ({ ...entry }));
    if (previous.current) {
      carried.push({ ...previous.current });
    }
    this.playedHistory = [...carried, ...this.playedHistory];
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
