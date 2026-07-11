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
