import { describe, it, expect, beforeEach } from "vitest";
import { renderHook, act } from "@testing-library/react";
import useAuthToken, { AUTH_TOKEN_KEY } from "../src/useAuthToken";

function token(exp: number): string {
  const header = btoa(JSON.stringify({ exp })).replace(/=+$/, "");
  return `${header}.payload.signature`;
}

const unexpired = token(Math.floor(Date.now() / 1000) + 60 * 60);
const expired = token(Math.floor(Date.now() / 1000) - 60);

describe("useAuthToken", () => {
  beforeEach(() => localStorage.clear());

  // no request, no gate: the app opens straight into the library
  it("trusts an unexpired stored token on sight", () => {
    localStorage.setItem(AUTH_TOKEN_KEY, unexpired);

    const { result } = renderHook(() => useAuthToken());

    expect(result.current[0]).toBe(unexpired);
  });

  it("drops an expired stored token without a request", () => {
    localStorage.setItem(AUTH_TOKEN_KEY, expired);

    const { result } = renderHook(() => useAuthToken());

    expect(result.current[0]).toBeNull();
    expect(localStorage.getItem(AUTH_TOKEN_KEY)).toBeNull();
  });

  it("keeps a token it cannot parse", () => {
    localStorage.setItem(AUTH_TOKEN_KEY, "garbage");

    const { result } = renderHook(() => useAuthToken());

    expect(result.current[0]).toBe("garbage");
  });

  it("has no token when nothing is stored", () => {
    const { result } = renderHook(() => useAuthToken());

    expect(result.current[0]).toBeNull();
  });

  it("stores a token that is set", () => {
    const { result } = renderHook(() => useAuthToken());

    act(() => result.current[1](unexpired));

    expect(localStorage.getItem(AUTH_TOKEN_KEY)).toBe(unexpired);
  });

  it("removes the stored token when it is cleared", () => {
    localStorage.setItem(AUTH_TOKEN_KEY, unexpired);
    const { result } = renderHook(() => useAuthToken());

    act(() => result.current[1](""));

    expect(localStorage.getItem(AUTH_TOKEN_KEY)).toBeNull();
  });
});
