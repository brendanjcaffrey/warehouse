import { ReactNode, useState, useEffect } from "react";
import { useSetAtom } from "jotai";
import useAuthToken from "./useAuthToken";
import AuthForm from "./AuthForm";
import AuthVerifier from "./AuthVerifier";
import { clearAuthFnAtom } from "./State";

interface AuthWrapperProps {
  children: ReactNode;
}

function AuthWrapper({ children }: AuthWrapperProps) {
  const [authToken, setAuthToken] = useAuthToken();
  const [authVerified, setAuthVerified] = useState(false);
  const setClearAuthFn = useSetAtom(clearAuthFnAtom);

  useEffect(() => {
    setClearAuthFn({
      fn: () => {
        setAuthToken("");
        setAuthVerified(false);
      },
    });
  }, [setAuthToken, setAuthVerified, setClearAuthFn]);

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
