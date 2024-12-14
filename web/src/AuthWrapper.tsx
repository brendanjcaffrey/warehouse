import { ReactNode, useState } from "react";
import useAuthToken from "./useAuthToken";
import AuthForm from "./AuthForm";
import AuthVerifier from "./AuthVerifier";

interface AuthWrapperProps {
  children: ReactNode;
}

function AuthWrapper({ children }: AuthWrapperProps) {
  const [authToken, setAuthToken] = useAuthToken();
  const [authVerified, setAuthVerified] = useState(false);

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
