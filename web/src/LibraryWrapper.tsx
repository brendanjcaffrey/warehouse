import { ReactNode, useState, useEffect } from "react";
import DelayedElement from "./DelayedElement";
import CenteredHalfAlert from "./CenteredHalfAlert";
import library from "./Library";
import { isTypedMessage, isErrorMessage, START_SYNC_TYPE } from "./WorkerTypes";

const SyncWorker = new Worker(new URL("./SyncWorker.ts", import.meta.url), {
  type: "module",
});

interface SyncWrapperProps {
  children: ReactNode;
}

function SyncWrapper({ children }: SyncWrapperProps) {
  const [error, setError] = useState("");
  const [hasLibrary, setHasLibrary] = useState(false);

  useEffect(() => {
    library().setErrorListener((error) => {
      setError(error);
    });

    library()
      .hasAny()
      .then((hasAny) => {
        setHasLibrary(hasAny);
        if (!hasAny) {
          SyncWorker.postMessage({
            type: START_SYNC_TYPE,
            authToken: localStorage.getItem("authToken"),
          });
        }
      });

    SyncWorker.onmessage = (m: MessageEvent) => {
      const { data } = m;
      if (!isTypedMessage(data)) {
        return;
      }

      if (isErrorMessage(data)) {
        setError(`worker error: ${data.error}`);
      }
    };

    return () => {
      SyncWorker.onmessage = null;
    };
  });

  if (error) {
    return <CenteredHalfAlert severity="error">{error}</CenteredHalfAlert>;
  } else if (hasLibrary) {
    return <>{children}</>;
  } else {
    return (
      <DelayedElement>
        <CenteredHalfAlert severity="info">
          Fetching library...
        </CenteredHalfAlert>
      </DelayedElement>
    );
  }
}

export default SyncWrapper;
