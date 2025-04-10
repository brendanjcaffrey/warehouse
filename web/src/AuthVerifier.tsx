import { useState, useEffect, useCallback } from "react";
import axios, { isAxiosError } from "axios";
import DelayedElement from "./DelayedElement";
import CenteredHalfAlert from "./CenteredHalfAlert";
import { AuthQueryResponse } from "./generated/messages";

interface AuthVerifierProps {
  authToken: string;
  setAuthToken: (authToken: string) => void;
  setAuthVerified: (authChecked: boolean) => void;
}

function AuthVerifier({
  authToken,
  setAuthToken,
  setAuthVerified,
}: AuthVerifierProps) {
  const [error, setError] = useState("");

  const checkAuth = useCallback(async () => {
    try {
      const { data } = await axios.get("/api/auth", {
        responseType: "arraybuffer",
        headers: { Authorization: `Bearer ${authToken}` },
      });

      const msg = AuthQueryResponse.deserialize(data);
      if (msg.isAuthed) {
        setAuthVerified(true);
      } else {
        setAuthToken("");
      }
    } catch (error) {
      console.error(error);
      console.log("window.navigator.onLine", window.navigator.onLine);
      if (
        isAxiosError(error) &&
        (!window.navigator.onLine || error.code === "ERR_NETWORK")
      ) {
        setAuthVerified(true);
      } else {
        setError("An error occurred while trying to verify authentication.");
      }
    }
  }, [authToken, setAuthToken, setAuthVerified]);

  useEffect(() => {
    checkAuth();
  });

  if (error) {
    return <CenteredHalfAlert severity="error">{error}</CenteredHalfAlert>;
  } else {
    return (
      <DelayedElement>
        <CenteredHalfAlert severity="info">Verifying auth...</CenteredHalfAlert>
      </DelayedElement>
    );
  }
}

export default AuthVerifier;
