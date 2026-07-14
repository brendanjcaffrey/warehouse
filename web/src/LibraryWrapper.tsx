import { ReactNode, useState, useEffect } from "react";
import { Button } from "react-bootstrap";
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
import { SyncWorker } from "./SyncWorker";
import { DownloadWorker } from "./DownloadWorker";
import { updatePersister } from "./UpdatePersister";
import { AUTH_TOKEN_KEY } from "./useAuthToken";

interface LibraryWrapperProps {
  children: ReactNode;
}

function LibraryWrapper({ children }: LibraryWrapperProps) {
  const [error, setError] = useState("");
  const [databaseInitialized, setDatabaseInitialized] = useState(false);
  const [hasLibrary, setHasLibrary] = useState(false);
  const [syncFinished, setSyncFinished] = useState(false);
  const [offline, setOffline] = useState(false);

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
      }

      if (IsSyncSucceededMessage(data)) {
        setSyncFinished(true);
        updatePersister().setHasLibraryMetadata(true);
        DownloadWorker.postMessage({
          type: SYNC_SUCCEEDED_TYPE,
        } as TypedMessage);
      }
    };

    SyncWorker.postMessage({
      type: START_SYNC_TYPE,
      authToken: localStorage.getItem(AUTH_TOKEN_KEY),
      updateTimeNs: library().getUpdateTimeNs(),
      browserOnline: navigator.onLine,
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
  } else if (hasLibrary && (syncFinished || offline)) {
    return <>{children}</>;
  } else {
    // a sync that can't reach the server hangs rather than failing (vpn off, captive
    // portal), so offer the stored library instead of waiting on it forever. nothing to
    // offer if we don't have one yet, & a sync that lands later still takes effect
    const useOffline = hasLibrary ? (
      <Button size="sm" variant="secondary" onClick={() => setOffline(true)}>
        Use Offline
      </Button>
    ) : undefined;

    return (
      <DelayedElement>
        <CenteredHalfAlert severity="info" action={useOffline}>
          Fetching library...
        </CenteredHalfAlert>
      </DelayedElement>
    );
  }
}

export default LibraryWrapper;
