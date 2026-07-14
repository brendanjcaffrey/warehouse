import { ReactNode, useEffect, useRef } from "react";
import { useSetAtom } from "jotai";
import useAuthToken from "./useAuthToken";
import AuthForm from "./AuthForm";
import refreshAuthToken from "./AuthRefresh";
import { DownloadWorker } from "./DownloadWorker";
import { AuthTokenMessage, SET_AUTH_TOKEN_TYPE } from "./WorkerTypes";
import { clearAuthFnAtom } from "./State";
import { updatePersister } from "./UpdatePersister";

interface AuthWrapperProps {
  children: ReactNode;
}

function AuthWrapper({ children }: AuthWrapperProps) {
  const [authToken, setAuthToken] = useAuthToken();
  const setClearAuthFn = useSetAtom(clearAuthFnAtom);
  const refreshed = useRef(false);
  const tokenRef = useRef(authToken);
  tokenRef.current = authToken;

  useEffect(() => {
    DownloadWorker.postMessage({
      type: SET_AUTH_TOKEN_TYPE,
      authToken,
    } as AuthTokenMessage);
    updatePersister().setAuthToken(authToken);
  }, [authToken]);

  useEffect(() => {
    setClearAuthFn({ fn: () => setAuthToken("") });
  }, [setAuthToken, setClearAuthFn]);

  // refreshes the token stored at startup, once. deliberately not keyed on the token: a
  // refresh writes a new one, which would re-fire the effect & refresh forever
  useEffect(() => {
    const stored = tokenRef.current;
    if (refreshed.current || !stored) return;
    refreshed.current = true;

    refreshAuthToken(stored).then((token) => setAuthToken(token ?? ""));
  }, [setAuthToken]);

  if (!authToken) {
    return <AuthForm setAuthToken={setAuthToken} />;
  }

  return <>{children}</>;
}

export default AuthWrapper;
