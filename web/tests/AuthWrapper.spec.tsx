import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import { Provider, createStore } from "jotai";
import AuthWrapper from "../src/AuthWrapper";
import { AUTH_TOKEN_KEY } from "../src/useAuthToken";

vi.mock("../src/DownloadWorker", () => ({
  DownloadWorker: { postMessage: vi.fn() },
}));

vi.mock("../src/UpdatePersister", () => ({
  updatePersister: () => ({ setAuthToken: vi.fn() }),
}));

vi.mock("../src/AuthRefresh", () => ({ default: vi.fn() }));

const refreshAuthToken = vi.mocked(
  (await import("../src/AuthRefresh")).default
);

function token(exp: number): string {
  const header = btoa(JSON.stringify({ exp })).replace(/=+$/, "");
  return `${header}.payload.signature`;
}

const stored = token(Math.floor(Date.now() / 1000) + 60 * 60);

function renderWrapper() {
  render(
    <Provider store={createStore()}>
      <AuthWrapper>
        <div>library</div>
      </AuthWrapper>
    </Provider>
  );
}

describe("AuthWrapper", () => {
  beforeEach(() => {
    localStorage.clear();
    vi.clearAllMocks();
    refreshAuthToken.mockResolvedValue(stored);
  });

  afterEach(() => cleanup());

  it("shows the login form when there is no token", () => {
    renderWrapper();

    expect(screen.getByText("Sign In")).toBeTruthy();
    expect(refreshAuthToken).not.toHaveBeenCalled();
  });

  // the refresh runs in the background & never gates the ui
  it("shows the library right away when a token is stored", () => {
    localStorage.setItem(AUTH_TOKEN_KEY, stored);

    renderWrapper();

    expect(screen.getByText("library")).toBeTruthy();
  });

  it("refreshes the stored token in the background", async () => {
    localStorage.setItem(AUTH_TOKEN_KEY, stored);
    const refreshed = token(Math.floor(Date.now() / 1000) + 2 * 60 * 60);
    refreshAuthToken.mockResolvedValue(refreshed);

    renderWrapper();

    await waitFor(() =>
      expect(localStorage.getItem(AUTH_TOKEN_KEY)).toBe(refreshed)
    );
    expect(refreshAuthToken).toHaveBeenCalledOnce();
    expect(screen.getByText("library")).toBeTruthy();
  });

  it("logs out when the server rejects the stored token", async () => {
    localStorage.setItem(AUTH_TOKEN_KEY, stored);
    refreshAuthToken.mockResolvedValue(null);

    renderWrapper();

    await waitFor(() => expect(screen.getByText("Sign In")).toBeTruthy());
    expect(localStorage.getItem(AUTH_TOKEN_KEY)).toBeNull();
  });

  // vpn off / offline: refreshAuthToken hands back the token it was given
  it("stays logged in when the refresh cannot reach the server", async () => {
    localStorage.setItem(AUTH_TOKEN_KEY, stored);

    renderWrapper();

    await waitFor(() => expect(refreshAuthToken).toHaveBeenCalledOnce());
    expect(screen.getByText("library")).toBeTruthy();
    expect(localStorage.getItem(AUTH_TOKEN_KEY)).toBe(stored);
  });
});
