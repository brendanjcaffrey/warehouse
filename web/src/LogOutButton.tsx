import { useAtomValue } from "jotai";
import { Button } from "react-bootstrap";
import { clearAuthFnAtom, clearSettingsFnAtom } from "./State";
import library from "./Library";
import downloadsStore from "./DownloadsStore";
import { updatePersister } from "./UpdatePersister";
import { DownloadWorker } from "./DownloadWorker";
import { player } from "./Player";
import { files } from "./Files";
import { CLEARED_ALL_TYPE, TypedMessage } from "./WorkerTypes";

interface LogOutButtonProps {
  size?: "sm" | "lg";
}

function LogOutButton({ size }: LogOutButtonProps) {
  const clearAuthFn = useAtomValue(clearAuthFnAtom);
  const clearSettingsFn = useAtomValue(clearSettingsFnAtom);

  async function clearAllState() {
    clearAuthFn.fn();
    clearSettingsFn.fn();
    library().clear();
    library().clearStoredMetadata();
    await player().reset();
    await files().clearAll();
    DownloadWorker.postMessage({ type: CLEARED_ALL_TYPE } as TypedMessage);
    updatePersister().setHasLibraryMetadata(false);
    updatePersister().clearPending();
    downloadsStore().clear();
  }

  return (
    <Button size={size} variant="danger" onClick={clearAllState}>
      Log Out
    </Button>
  );
}

export default LogOutButton;
