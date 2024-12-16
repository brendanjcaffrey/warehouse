import { ReactNode } from "react";
import { Alert, AlertColor } from "@mui/material";

interface CenteredHalfAlertProps {
  severity?: AlertColor;
  children: ReactNode;
}

function CenteredHalfAlert({ severity, children }: CenteredHalfAlertProps) {
  return (
    <Alert
      severity={severity}
      sx={{ width: "50%", marginLeft: "25%", marginTop: "12px" }}
    >
      {children}
    </Alert>
  );
}

export default CenteredHalfAlert;
