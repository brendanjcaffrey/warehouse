import { useAtomValue } from "jotai";
import { Box, Button } from "@mui/material";
import { Logout } from "@mui/icons-material";
import { clearAuthFnAtom, clearSettingsFnAtom } from "./State";
import library from "./Library";

function LogOut({ height }: { height: string }) {
  const clearAuthFn = useAtomValue(clearAuthFnAtom);
  const clearSettingsFn = useAtomValue(clearSettingsFnAtom);

  function clearAllState() {
    clearAuthFn.fn();
    clearSettingsFn.fn();
    library().clear();
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
