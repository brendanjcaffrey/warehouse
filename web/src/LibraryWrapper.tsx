import { ReactNode, useState, useEffect } from "react";
import DelayedElement from "./DelayedElement";
import CenteredHalfAlert from "./CenteredHalfAlert";
import library from "./Library";
import {
  IsTypedMessage,
  IsErrorMessage,
  IsLibraryMetadataMessage,
  IsSyncSucceededMessage,
  StartSyncMessage,
  TypedMessage,
  START_SYNC_TYPE,
  SYNC_SUCCEEDED_TYPE,
} from "./WorkerTypes";
import { DownloadWorker } from "./DownloadWorkerHandle";
import { updatePersister } from "./UpdatePersister";
import { AUTH_TOKEN_KEY } from "./useAuthToken";

const SyncWorker = new Worker(new URL("./SyncWorker.ts", import.meta.url), {
  type: "module",
});

interface LibraryWrapperProps {
  children: ReactNode;
}

function LibraryWrapper({ children }: LibraryWrapperProps) {
  const [error, setError] = useState("");
  const [databaseInitialized, setDatabaseInitialized] = useState(false);
  const [hasLibrary, setHasLibrary] = useState(false);
  const [syncFinished, setSyncFinished] = useState(false);

  useEffect(() => {
    library().setInitializedListener(() => {
      setDatabaseInitialized(true);
    });
  }, []);

  useEffect(() => {
    if (!databaseInitialized) {
      return;
    }

    library().setErrorListener((error) => {
      setError(error);
    });

    SyncWorker.onmessage = (m: MessageEvent) => {
      const { data } = m;
      if (!IsTypedMessage(data)) {
        return;
      }

      if (IsErrorMessage(data)) {
        setError(`worker error: ${data.error}`);
      }

      if (IsLibraryMetadataMessage(data)) {
        library().putMetadata(data);
        updatePersister().setHasLibraryMetadata(true);
      }

      if (IsSyncSucceededMessage(data)) {
        setSyncFinished(true);
        DownloadWorker.postMessage({
          type: SYNC_SUCCEEDED_TYPE,
        } as TypedMessage);
      }
    };

    SyncWorker.postMessage({
      type: START_SYNC_TYPE,
      authToken: localStorage.getItem(AUTH_TOKEN_KEY),
      updateTimeNs: library().getUpdateTimeNs(),
    } as StartSyncMessage);

    return () => {
      SyncWorker.onmessage = null;
    };
  }, [databaseInitialized]);

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
