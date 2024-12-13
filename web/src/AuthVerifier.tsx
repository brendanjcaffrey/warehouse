import { useState, useEffect, useCallback } from "react";
import { Alert } from "@mui/material";
import axios from "axios";
import DelayedElement from "./DelayedElement";

interface AuthVerifierProps {
  authToken: string;
  setAuthToken: (authToken: string) => void;
  setAuthVerified: (authChecked: boolean) => void;
}

interface HeartbeatResponse {
  is_authed: boolean;
}

function clearAxiosAuthHeader() {
  delete axios.defaults.headers.common["Authorization"];
}

function AuthVerifier({
  authToken,
  setAuthToken,
  setAuthVerified,
}: AuthVerifierProps) {
  const [error, setError] = useState("");

  const checkAuth = useCallback(async () => {
    try {
      axios.defaults.headers.common["Authorization"] = "Bearer " + authToken;
      const { data: response } = await axios.get<HeartbeatResponse>(
        "/api/heartbeat"
      );
      if (response.is_authed) {
        setAuthVerified(true);
      } else {
        clearAxiosAuthHeader();
        setAuthToken("");
      }
    } catch (error) {
      clearAxiosAuthHeader();
      console.error(error);
      setError("An error occurred while trying to verify authentication.");
    }
  }, [authToken, setAuthToken, setAuthVerified]);

  useEffect(() => {
    checkAuth();
  });

  if (error) {
    return (
      <Alert severity="error" sx={{ width: "50%", marginLeft: "25%" }}>
        {error}
      </Alert>
    );
  } else {
    return (
      <DelayedElement>
        <Alert severity="info" sx={{ width: "50%", marginLeft: "25%" }}>
          Verifying auth...
        </Alert>
      </DelayedElement>
    );
  }
}

export default AuthVerifier;
