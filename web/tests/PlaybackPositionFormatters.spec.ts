import { expect, test } from "vitest";
import {
  FormatPlaybackPosition,
  FormatPlaybackPositionWithMillis,
  UnformatPlaybackPositionWithMillis,
} from "../src/PlaybackPositionFormatters";

test("FormatPlaybackPosition", () => {
  expect(FormatPlaybackPosition(0)).toBe("0:00");
  expect(FormatPlaybackPosition(1)).toBe("0:01");
  expect(FormatPlaybackPosition(10)).toBe("0:10");
  expect(FormatPlaybackPosition(60)).toBe("1:00");
  expect(FormatPlaybackPosition(61)).toBe("1:01");
  expect(FormatPlaybackPosition(120)).toBe("2:00");
  expect(FormatPlaybackPosition(121)).toBe("2:01");
  expect(FormatPlaybackPosition(3600)).toBe("60:00");
});

test("FormatPlaybackPositionWithMillis", () => {
  expect(FormatPlaybackPositionWithMillis(0)).toBe("0:00");
  expect(FormatPlaybackPositionWithMillis(0.1)).toBe("0:00.1");
  expect(FormatPlaybackPositionWithMillis(0.12)).toBe("0:00.12");
  expect(FormatPlaybackPositionWithMillis(0.123)).toBe("0:00.123");
  expect(FormatPlaybackPositionWithMillis(1)).toBe("0:01");
  expect(FormatPlaybackPositionWithMillis(1.2)).toBe("0:01.2");
  expect(FormatPlaybackPositionWithMillis(10)).toBe("0:10");
  expect(FormatPlaybackPositionWithMillis(10.3)).toBe("0:10.3");
  expect(FormatPlaybackPositionWithMillis(60)).toBe("1:00");
  expect(FormatPlaybackPositionWithMillis(60.4)).toBe("1:00.4");
  expect(FormatPlaybackPositionWithMillis(61)).toBe("1:01");
  expect(FormatPlaybackPositionWithMillis(61.5)).toBe("1:01.5");
  expect(FormatPlaybackPositionWithMillis(120)).toBe("2:00");
  expect(FormatPlaybackPositionWithMillis(120.6)).toBe("2:00.6");
  expect(FormatPlaybackPositionWithMillis(121)).toBe("2:01");
  expect(FormatPlaybackPositionWithMillis(121.7)).toBe("2:01.7");
  expect(FormatPlaybackPositionWithMillis(180.005)).toBe("3:00.005");
  expect(FormatPlaybackPositionWithMillis(180.04)).toBe("3:00.04");
  expect(FormatPlaybackPositionWithMillis(180.045)).toBe("3:00.045");
  expect(FormatPlaybackPositionWithMillis(180.3)).toBe("3:00.3");
  expect(FormatPlaybackPositionWithMillis(180.34)).toBe("3:00.34");
  expect(FormatPlaybackPositionWithMillis(180.345)).toBe("3:00.345");
  expect(FormatPlaybackPositionWithMillis(3600)).toBe("60:00");
  expect(FormatPlaybackPositionWithMillis(3600.8)).toBe("60:00.8");
  expect(FormatPlaybackPositionWithMillis(3600.8)).toBe("60:00.8");
});

test("UnformatPlaybackPositionWithMillis", () => {
  expect(UnformatPlaybackPositionWithMillis("0:00")).toBe(0);
  expect(UnformatPlaybackPositionWithMillis("0:00.")).toBe(0);
  expect(UnformatPlaybackPositionWithMillis("0:00.1")).toBe(0.1);
  expect(UnformatPlaybackPositionWithMillis("0:00.12")).toBe(0.12);
  expect(UnformatPlaybackPositionWithMillis("0:00.123")).toBe(0.123);
  expect(UnformatPlaybackPositionWithMillis("0:01")).toBe(1);
  expect(UnformatPlaybackPositionWithMillis("0:01.")).toBe(1);
  expect(UnformatPlaybackPositionWithMillis("0:01.2")).toBe(1.2);
  expect(UnformatPlaybackPositionWithMillis("0:10")).toBe(10);
  expect(UnformatPlaybackPositionWithMillis("0:10.")).toBe(10);
  expect(UnformatPlaybackPositionWithMillis("0:10.3")).toBe(10.3);
  expect(UnformatPlaybackPositionWithMillis("1:00")).toBe(60);
  expect(UnformatPlaybackPositionWithMillis("1:00.")).toBe(60);
  expect(UnformatPlaybackPositionWithMillis("1:00.4")).toBe(60.4);
  expect(UnformatPlaybackPositionWithMillis("1:01")).toBe(61);
  expect(UnformatPlaybackPositionWithMillis("1:01.")).toBe(61);
  expect(UnformatPlaybackPositionWithMillis("1:01.5")).toBe(61.5);
  expect(UnformatPlaybackPositionWithMillis("2:00")).toBe(120);
  expect(UnformatPlaybackPositionWithMillis("2:00.")).toBe(120);
  expect(UnformatPlaybackPositionWithMillis("2:00.6")).toBe(120.6);
  expect(UnformatPlaybackPositionWithMillis("2:01")).toBe(121);
  expect(UnformatPlaybackPositionWithMillis("2:01.")).toBe(121);
  expect(UnformatPlaybackPositionWithMillis("2:01.7")).toBe(121.7);
  expect(UnformatPlaybackPositionWithMillis("3:00.005")).toBe(180.005);
  expect(UnformatPlaybackPositionWithMillis("60:00")).toBe(3600);
  expect(UnformatPlaybackPositionWithMillis("60:00.")).toBe(3600);
  expect(UnformatPlaybackPositionWithMillis("60:00.8")).toBe(3600.8);
});
