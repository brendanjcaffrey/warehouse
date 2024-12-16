import { useAtomValue } from "jotai";
import { Box, Button } from "@mui/material";
import { Logout } from "@mui/icons-material";
import { clearAuthFnAtom, clearSettingsFnAtom } from "./State";
import library from "./Library";
import { ArtworkWorker } from "./ArtworkWorkerHandle";
import { CLEAR_ALL_TYPE } from "./WorkerTypes";

function LogOut({ height }: { height: string }) {
  const clearAuthFn = useAtomValue(clearAuthFnAtom);
  const clearSettingsFn = useAtomValue(clearSettingsFnAtom);

  function clearAllState() {
    clearAuthFn.fn();
    clearSettingsFn.fn();
    library().clear();
    ArtworkWorker.postMessage({ type: CLEAR_ALL_TYPE });
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
