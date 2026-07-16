import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import LibraryWrapper from "../src/LibraryWrapper";
import {
  IsTypedMessage,
  SYNC_SUCCEEDED_TYPE,
  TypedMessage,
} from "../src/WorkerTypes";

const libraryMock = {
  setInitializedListener: vi.fn((fn: () => void) => fn()),
  setErrorListener: vi.fn(),
  getUpdateTimeNs: vi.fn(() => 0),
  hasAny: vi.fn(async () => true),
  putMetadata: vi.fn(),
};

vi.mock("../src/Library", () => ({ default: () => libraryMock }));

vi.mock("../src/SyncWorker", () => ({
  // a sync that never answers: this is the vpn-off case
  SyncWorker: { postMessage: vi.fn(), onmessage: null },
}));

vi.mock("../src/DownloadWorker", () => ({
  DownloadWorker: { postMessage: vi.fn() },
}));

vi.mock("../src/UpdatePersister", () => ({
  updatePersister: () => ({ setHasLibraryMetadata: vi.fn() }),
}));

const { SyncWorker } = await import("../src/SyncWorker");

// the fetching alert only appears after DelayedElement's one second
const DELAYED = { timeout: 2000 };

function renderWrapper() {
  render(
    <LibraryWrapper>
      <div>library</div>
    </LibraryWrapper>
  );
}

function syncSucceeds() {
  const message = { type: SYNC_SUCCEEDED_TYPE } as TypedMessage;
  expect(IsTypedMessage(message)).toBe(true);
  SyncWorker.onmessage?.({ data: message } as MessageEvent);
}

describe("LibraryWrapper", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    libraryMock.setInitializedListener.mockImplementation((fn: () => void) =>
      fn()
    );
    libraryMock.hasAny.mockResolvedValue(true);
  });

  afterEach(() => cleanup());

  it("shows the library once the sync finishes", async () => {
    renderWrapper();

    await waitFor(() => expect(SyncWorker.postMessage).toHaveBeenCalled());
    syncSucceeds();

    expect(await screen.findByText("library")).toBeTruthy();
  });

  it("offers to use the stored library while a sync hangs", async () => {
    renderWrapper();

    const button = await screen.findByRole(
      "button",
      { name: "Use Offline" },
      DELAYED
    );
    fireEvent.click(button);

    expect(await screen.findByText("library")).toBeTruthy();
  });

  // nothing stored to fall back to, so waiting is all we can do
  it("does not offer to use offline without a stored library", async () => {
    libraryMock.hasAny.mockResolvedValue(false);

    renderWrapper();

    expect(
      await screen.findByText("Fetching library...", {}, DELAYED)
    ).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Use Offline" })).toBeNull();
  });

  it("shows the error instead of the fetching alert", async () => {
    libraryMock.setErrorListener.mockImplementation((fn: (e: string) => void) =>
      fn("database is broken")
    );

    renderWrapper();

    expect(await screen.findByText("database is broken")).toBeTruthy();
    expect(screen.queryByText("Fetching library...")).toBeNull();
  });
});
