import { useState, useEffect } from "react";

const AUTH_TOKEN_KEY = "authToken";

function useAuthToken() {
  const [token, setToken] = useState<string | null>(() =>
    localStorage.getItem(AUTH_TOKEN_KEY)
  );

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
