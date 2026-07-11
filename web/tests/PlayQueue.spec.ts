import { expect, test } from "vitest";
import { PlayQueue } from "../src/PlayQueue";
import { PlaylistTrack } from "../src/Types";

// a queue of tracks a, b, c, ... in a single source, offsets matching position
function makeEntries(ids: string): PlaylistTrack[] {
  return ids.split("").map((id, i) => ({
    playlistId: "p",
    trackId: id,
    playlistOffset: i,
  }));
}

function ids(entries: PlaylistTrack[]): string {
  return entries.map((e) => e.trackId).join("");
}

function order(queue: PlayQueue): string {
  // walk the whole queue from the current position without wrapping, reading
  // ids off; used to assert the play order
  const ids: string[] = [];
  let entry = queue.current;
  while (entry) {
    ids.push(entry.trackId);
    if (!queue.advance(false)) {
      break;
    }
    entry = queue.current;
  }
  return ids.join("");
}

test("an empty queue has no current track", () => {
  const queue = new PlayQueue();
  expect(queue.isEmpty).toBe(true);
  expect(queue.current).toBeUndefined();
  expect(queue.advance()).toBe(false);
  expect(queue.goBack()).toBe(false);
});

test("starts at the given index so previous walks back through earlier tracks", () => {
  const queue = new PlayQueue(makeEntries("abcd"), 2);
  expect(queue.current?.trackId).toBe("c");
  expect(queue.goBack()).toBe(true);
  expect(queue.current?.trackId).toBe("b");
});

test("advance stops at the end unless wrapping", () => {
  const queue = new PlayQueue(makeEntries("abc"), 2);
  expect(queue.advance(false)).toBe(false);
  expect(queue.current?.trackId).toBe("c");
  expect(queue.advance(true)).toBe(true);
  expect(queue.current?.trackId).toBe("a");
});

test("goBack wraps around to the last track", () => {
  const queue = new PlayQueue(makeEntries("abc"), 0);
  expect(queue.goBack()).toBe(true);
  expect(queue.current?.trackId).toBe("c");
});

test("goBack stays on the first track when not wrapping", () => {
  const queue = new PlayQueue(makeEntries("abc"), 0);
  expect(queue.goBack(false)).toBe(false);
  expect(queue.current?.trackId).toBe("a");
});

test("goBack steps back without wrapping when not on the first track", () => {
  const queue = new PlayQueue(makeEntries("abc"), 2);
  expect(queue.goBack(false)).toBe(true);
  expect(queue.current?.trackId).toBe("b");
});

test("play next inserts right after the current track", () => {
  const queue = new PlayQueue(makeEntries("abc"), 0);
  const extra: PlaylistTrack = {
    playlistId: "p",
    trackId: "x",
    playlistOffset: -1,
  };
  queue.playNext(extra);
  expect(order(queue)).toBe("axbc");
});

test("play next on an empty queue makes the track the whole queue", () => {
  const queue = new PlayQueue();
  const extra: PlaylistTrack = {
    playlistId: "p",
    trackId: "x",
    playlistOffset: -1,
  };
  queue.playNext(extra);
  expect(queue.current?.trackId).toBe("x");
  expect(queue.length).toBe(1);
});

test("shuffle reorders the upcoming tracks but keeps the current and earlier ones", () => {
  const queue = new PlayQueue(makeEntries("abcde"), 1);
  queue.setShuffled(true);
  // current stays on b
  expect(queue.current?.trackId).toBe("b");
  // the already-played head is untouched
  expect(queue.goBack()).toBe(true);
  expect(queue.current?.trackId).toBe("a");
  queue.advance();
  // the upcoming tracks are the same set, just reordered
  const played = order(queue);
  expect(played[0]).toBe("b");
  expect(played.slice(1).split("").sort().join("")).toBe("cde");
  expect(played.length).toBe(4);
});

test("turning shuffle off restores the original order at the current track", () => {
  const queue = new PlayQueue(makeEntries("abcde"), 1);
  queue.setShuffled(true);
  queue.setShuffled(false);
  // back to the original order, still sitting on b
  expect(queue.current?.trackId).toBe("b");
  expect(order(queue)).toBe("bcde");
});

test("a shuffled queue built with a preserved context un-shuffles to it", () => {
  const context = makeEntries("abcd");
  // entries already reordered (d a c b), current is the first, context original
  const entries = [context[3], context[0], context[2], context[1]];
  const queue = new PlayQueue(entries, 0, true, context);
  expect(queue.current?.trackId).toBe("d");
  queue.setShuffled(false);
  // restored order continues from d's spot in the original list
  expect(order(queue)).toBe("d");
  expect(queue.length).toBe(4);
});

test("the same track can appear twice and stays distinct", () => {
  const a = { playlistId: "p", trackId: "a", playlistOffset: 0 };
  const aAgain = { playlistId: "p", trackId: "a", playlistOffset: 2 };
  const queue = new PlayQueue(
    [a, { playlistId: "p", trackId: "b", playlistOffset: 1 }, aAgain],
    0
  );
  const extra = { playlistId: "p", trackId: "x", playlistOffset: -1 };
  // playing next after the first a inserts between it and b, not near the second
  queue.playNext(extra);
  expect(order(queue)).toBe("axba");
});

test("slice returns the upcoming tracks starting at the current one", () => {
  const queue = new PlayQueue(makeEntries("abcde"), 3);
  expect(queue.slice(3).map((e) => e.trackId)).toEqual(["d", "e", "a"]);
});

test("upcoming lists every track after the current one in play order", () => {
  const queue = new PlayQueue(makeEntries("abcde"), 1);
  expect(ids(queue.upcoming)).toBe("cde");
  queue.advance();
  expect(ids(queue.upcoming)).toBe("de");
});

test("upcoming is empty on the last track", () => {
  const queue = new PlayQueue(makeEntries("abc"), 2);
  expect(queue.upcoming).toEqual([]);
});

test("advancing records the tracks played in order", () => {
  const queue = new PlayQueue(makeEntries("abcd"), 0);
  expect(queue.history).toEqual([]);
  queue.advance();
  queue.advance();
  expect(ids(queue.history)).toBe("ab");
  expect(queue.current?.trackId).toBe("c");
});

test("going back records the current track as played", () => {
  const queue = new PlayQueue(makeEntries("abc"), 2);
  queue.goBack();
  expect(ids(queue.history)).toBe("c");
  expect(queue.current?.trackId).toBe("b");
});

test("history entries are copies, so a track played twice stays distinct", () => {
  const queue = new PlayQueue(makeEntries("ab"), 0);
  queue.advance();
  const [recorded] = queue.history;
  // the recorded entry is not the same object as any live queue entry
  expect(queue.upcoming).not.toContain(recorded);
  expect(recorded.trackId).toBe("a");
});

test("jump to upcoming records only the current track and drops the skipped ones", () => {
  const queue = new PlayQueue(makeEntries("abcde"), 0);
  expect(queue.jumpToUpcoming(2)).toBe(true);
  expect(queue.current?.trackId).toBe("d");
  // a was played, b and c were skipped without being recorded
  expect(ids(queue.history)).toBe("a");
  expect(ids(queue.upcoming)).toBe("e");
});

test("jump to upcoming rejects an out of range index", () => {
  const queue = new PlayQueue(makeEntries("abc"), 0);
  expect(queue.jumpToUpcoming(5)).toBe(false);
  expect(queue.jumpToUpcoming(-1)).toBe(false);
  expect(queue.current?.trackId).toBe("a");
  expect(queue.history).toEqual([]);
});

test("recording the current play again keeps the position, for repeat one", () => {
  const queue = new PlayQueue(makeEntries("ab"), 0);
  expect(queue.recordCurrentPlayed()).toBe(true);
  expect(queue.recordCurrentPlayed()).toBe(true);
  expect(ids(queue.history)).toBe("aa");
  expect(queue.current?.trackId).toBe("a");
});

test("inheriting history carries the old plays plus the interrupted track", () => {
  const first = new PlayQueue(makeEntries("abc"), 0);
  first.advance(); // a played, now on b
  const second = new PlayQueue(makeEntries("xyz"), 0);
  second.inheritHistory(first);
  // a was recorded, b was playing when it was replaced, then x's own history
  expect(ids(second.history)).toBe("ab");
  second.advance(); // x played
  expect(ids(second.history)).toBe("abx");
});
