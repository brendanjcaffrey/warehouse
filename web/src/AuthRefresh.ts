import axios from "axios";
import { AuthResponse } from "./generated/messages";

// refreshes the stored token in the background. this never gates the ui: the only thing
// it can do is end the session, & only when the server explicitly rejects us. returns the
// token to keep using, or null to log out
async function refreshAuthToken(authToken: string): Promise<string | null> {
  try {
    const { data } = await axios.put("/api/auth", undefined, {
      responseType: "arraybuffer",
      headers: { Authorization: `Bearer ${authToken}` },
    });

    const msg = AuthResponse.deserialize(new Uint8Array(data));
    if (msg.response === "token") return msg.token;
    if (msg.response === "error") return null;

    // an answer we can't read, leave the session alone
    return authToken;
  } catch (error) {
    // couldn't reach the server, or it's not a server. either way this is the network
    // or a broken server talking & must not read as the server rejecting the token
    console.error(error);
    return authToken;
  }
}

export default refreshAuthToken;
