import { ReactNode } from "react";
import { Alert, AlertColor } from "@mui/material";

interface CenteredHalfAlertProps {
  severity?: AlertColor;
  action?: ReactNode;
  children: ReactNode;
}

function CenteredHalfAlert({
  severity,
  action,
  children,
}: CenteredHalfAlertProps) {
  return (
    <Alert
      severity={severity}
      action={action}
      sx={{ width: "50%", marginLeft: "25%", marginTop: "12px" }}
    >
      {children}
    </Alert>
  );
}

export default CenteredHalfAlert;
