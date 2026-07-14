import { useState, useEffect } from "react";
import { isExpired } from "./JWT";

export const AUTH_TOKEN_KEY = "authToken";

function useAuthToken() {
  // a stored token is trusted on sight so the app opens without waiting on the network.
  // an expired one is dropped here, still without a request
  const [token, setToken] = useState<string | null>(() => {
    const stored = localStorage.getItem(AUTH_TOKEN_KEY);
    if (stored === null) return null;
    return isExpired(stored) ? null : stored;
  });

  useEffect(() => {
    if (token) {
      localStorage.setItem(AUTH_TOKEN_KEY, token);
    } else {
      localStorage.removeItem(AUTH_TOKEN_KEY);
    }
  }, [token]);

  return [token, setToken] as const;
}

export default useAuthToken;
