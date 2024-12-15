import { ReactNode, useState, useEffect } from "react";
import DelayedElement from "./DelayedElement";
import CenteredHalfAlert from "./CenteredHalfAlert";
import library from "./Library";
import {
  isTypedMessage,
  isErrorMessage,
  isSyncSucceededMessage,
  START_SYNC_TYPE,
} from "./WorkerTypes";

const SyncWorker = new Worker(new URL("./SyncWorker.ts", import.meta.url), {
  type: "module",
});

interface LibraryWrapperProps {
  children: ReactNode;
}

function LibraryWrapper({ children }: LibraryWrapperProps) {
  const [error, setError] = useState("");
  const [hasLibrary, setHasLibrary] = useState(false);
  const [syncFinished, setSyncFinished] = useState(false);

  useEffect(() => {
    library().setErrorListener((error) => {
      setError(error);
    });

    SyncWorker.onmessage = (m: MessageEvent) => {
      const { data } = m;
      if (!isTypedMessage(data)) {
        return;
      }

      if (isErrorMessage(data)) {
        setError(`worker error: ${data.error}`);
      }

      if (isSyncSucceededMessage(data)) {
        setSyncFinished(true);
      }
    };

    SyncWorker.postMessage({
      type: START_SYNC_TYPE,
      authToken: localStorage.getItem("authToken"),
    });

    return () => {
      SyncWorker.onmessage = null;
    };
  }, []);

  useEffect(() => {
    library()
      .hasAny()
      .then((hasAny) => {
        setHasLibrary(hasAny);
      });
  }, [syncFinished]);

  if (error) {
    return <CenteredHalfAlert severity="error">{error}</CenteredHalfAlert>;
  } else if (hasLibrary && syncFinished) {
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

export default LibraryWrapper;
