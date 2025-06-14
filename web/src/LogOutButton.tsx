import { useAtomValue } from "jotai";
import { Button, ButtonOwnProps } from "@mui/material";
import { Logout } from "@mui/icons-material";
import { clearAuthFnAtom, clearSettingsFnAtom } from "./State";
import library from "./Library";
import downloadsStore from "./Library";
import { updatePersister } from "./UpdatePersister";
import { DownloadWorker } from "./DownloadWorker";
import { player } from "./Player";
import { files } from "./Files";
import { CLEARED_ALL_TYPE, TypedMessage } from "./WorkerTypes";

interface LogOutButtonProps {
  size?: ButtonOwnProps["size"];
  sx?: ButtonOwnProps["sx"];
}

function LogOutButton({ size, sx }: LogOutButtonProps) {
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
    <Button
      color="primary"
      variant="text"
      size={size}
      sx={sx}
      startIcon={<Logout />}
      onClick={clearAllState}
    >
      Log Out
    </Button>
  );
}

export default LogOutButton;
