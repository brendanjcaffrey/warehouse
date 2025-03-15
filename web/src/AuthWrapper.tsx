import { ReactNode, useState, useEffect } from "react";
import { useSetAtom } from "jotai";
import useAuthToken from "./useAuthToken";
import AuthForm from "./AuthForm";
import AuthVerifier from "./AuthVerifier";
import { DownloadWorker } from "./DownloadWorkerHandle";
import { AuthTokenMessage, SET_AUTH_TOKEN_TYPE } from "./WorkerTypes";
import { clearAuthFnAtom } from "./State";
import { updatePersister } from "./UpdatePersister";

interface AuthWrapperProps {
  children: ReactNode;
}

function AuthWrapper({ children }: AuthWrapperProps) {
  const [authToken, setAuthToken] = useAuthToken();
  const [authVerified, setAuthVerified] = useState(false);
  const setClearAuthFn = useSetAtom(clearAuthFnAtom);

  useEffect(() => {
    DownloadWorker.postMessage({
      type: SET_AUTH_TOKEN_TYPE,
      authToken,
    } as AuthTokenMessage);
    updatePersister().setAuthToken(authToken);
  }, [authToken]);

  useEffect(() => {
    setClearAuthFn({
      fn: () => {
        setAuthToken("");
        setAuthVerified(false);
      },
    });
  }, [authToken, setAuthToken, setAuthVerified, setClearAuthFn]);

  if (!authToken) {
    return <AuthForm setAuthToken={setAuthToken} />;
  } else if (!authVerified) {
    return (
      <AuthVerifier
        authToken={authToken}
        setAuthVerified={setAuthVerified}
        setAuthToken={setAuthToken}
      />
    );
  } else {
    return <>{children}</>;
  }
}

export default AuthWrapper;
