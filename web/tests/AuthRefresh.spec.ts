import { describe, it, expect, vi, beforeEach } from "vitest";
import axios, { AxiosError } from "axios";
import refreshAuthToken from "../src/AuthRefresh";
import { AuthResponse } from "../src/generated/messages";

vi.mock("axios");

const put = vi.mocked(axios.put);

function responseOf(msg: AuthResponse) {
  return { data: msg.serialize().buffer };
}

describe("refreshAuthToken", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, "error").mockImplementation(() => {});
  });

  it("sends the token as a bearer token", async () => {
    put.mockResolvedValue(responseOf(new AuthResponse({ token: "refreshed" })));

    await refreshAuthToken("stored");

    expect(put).toHaveBeenCalledWith("/api/auth", undefined, {
      responseType: "arraybuffer",
      headers: { Authorization: "Bearer stored" },
    });
  });

  it("returns the refreshed token", async () => {
    put.mockResolvedValue(responseOf(new AuthResponse({ token: "refreshed" })));

    expect(await refreshAuthToken("stored")).toBe("refreshed");
  });

  // the only thing a refresh can do is end the session, & only on an explicit rejection
  it("returns null when the server rejects the token", async () => {
    put.mockResolvedValue(responseOf(new AuthResponse({ error: "bad token" })));

    expect(await refreshAuthToken("stored")).toBeNull();
  });

  it("keeps the token when the answer is empty", async () => {
    put.mockResolvedValue(responseOf(new AuthResponse({})));

    expect(await refreshAuthToken("stored")).toBe("stored");
  });

  it("keeps the token when the network is down", async () => {
    put.mockRejectedValue(new AxiosError("network error", "ERR_NETWORK"));

    expect(await refreshAuthToken("stored")).toBe("stored");
  });

  // vpn off: something that isn't the server answers, or the server 500s
  it("keeps the token when the response is not a 200", async () => {
    put.mockRejectedValue(new AxiosError("not found", "ERR_BAD_REQUEST"));

    expect(await refreshAuthToken("stored")).toBe("stored");
  });

  it("keeps the token when the body is not a parseable response", async () => {
    put.mockResolvedValue({ data: new Uint8Array([0xff, 0xff, 0xff]).buffer });

    expect(await refreshAuthToken("stored")).toBe("stored");
  });
});
