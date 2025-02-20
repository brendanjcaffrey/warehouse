import { useAtomValue } from "jotai";
import { Box, Button } from "@mui/material";
import { Logout } from "@mui/icons-material";
import { clearAuthFnAtom, clearSettingsFnAtom } from "./State";
import library from "./Library";
import { updatePersister } from "./UpdatePersister";
import { DownloadWorker } from "./DownloadWorkerHandle";
import { player } from "./Player";
import { files } from "./Files";
import { CLEARED_ALL_TYPE } from "./WorkerTypes";

function LogOut({ height }: { height: string }) {
  const clearAuthFn = useAtomValue(clearAuthFnAtom);
  const clearSettingsFn = useAtomValue(clearSettingsFnAtom);

  async function clearAllState() {
    clearAuthFn.fn();
    clearSettingsFn.fn();
    library().clear();
    await player().reset();
    await files().clearAll();
    DownloadWorker.postMessage({ type: CLEARED_ALL_TYPE });
    updatePersister().setHasLibraryMetadata(false);
    updatePersister().clearPending();
  }

  return (
    <Box sx={{ height: height }}>
      <Button
        color="info"
        variant="text"
        sx={{ width: "100%" }}
        startIcon={<Logout />}
        onClick={clearAllState}
      >
        Log Out
      </Button>
    </Box>
  );
}

export default LogOut;
