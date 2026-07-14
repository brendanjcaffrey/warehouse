import { describe, it, expect } from "vitest";
import { expiry, isExpired } from "../src/JWT";

function base64URL(value: object): string {
  return btoa(JSON.stringify(value))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

// the server puts exp in the header, see shared/jwt.rb
function token(
  header: object,
  payload: object = { username: "brendan" }
): string {
  return `${base64URL(header)}.${base64URL(payload)}.signature`;
}

describe("expiry", () => {
  it("reads exp out of the header", () => {
    const exp = 1_800_000_000;
    expect(expiry(token({ exp }))).toEqual(new Date(exp * 1000));
  });

  it("returns null when there is no exp", () => {
    expect(expiry(token({ alg: "HS256" }))).toBeNull();
  });

  it("returns null when exp is not a number", () => {
    expect(expiry(token({ exp: "soon" }))).toBeNull();
  });

  it("returns null for a token with the wrong number of segments", () => {
    expect(expiry("nope")).toBeNull();
    expect(expiry("one.two")).toBeNull();
  });

  it("returns null when the header is not base64 or not json", () => {
    expect(expiry("!!!.payload.signature")).toBeNull();
    expect(expiry(`${btoa("not json")}.payload.signature`)).toBeNull();
  });
});

describe("isExpired", () => {
  const now = new Date(1_800_000_000 * 1000);

  it("is true once exp has passed", () => {
    expect(isExpired(token({ exp: 1_799_999_999 }), now)).toBe(true);
  });

  it("is true exactly at exp", () => {
    expect(isExpired(token({ exp: 1_800_000_000 }), now)).toBe(true);
  });

  it("is false before exp", () => {
    expect(isExpired(token({ exp: 1_800_000_001 }), now)).toBe(false);
  });

  // the server is the judge of a token's validity, we'd rather refresh than lock out
  it("treats a token it can't parse as unexpired", () => {
    expect(isExpired("garbage", now)).toBe(false);
    expect(isExpired(token({ alg: "HS256" }), now)).toBe(false);
  });
});
