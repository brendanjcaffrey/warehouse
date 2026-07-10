import { ReactNode } from "react";
import { Alert } from "react-bootstrap";

type Severity = "error" | "info" | "success" | "warning";

const SEVERITY_TO_VARIANT: Record<Severity, string> = {
  error: "danger",
  info: "info",
  success: "success",
  warning: "warning",
};

interface CenteredHalfAlertProps {
  severity?: Severity;
  action?: ReactNode;
  children: ReactNode;
}

function CenteredHalfAlert({
  severity = "info",
  action,
  children,
}: CenteredHalfAlertProps) {
  return (
    <Alert
      variant={SEVERITY_TO_VARIANT[severity]}
      className="w-50 mx-auto"
      style={{ marginTop: "12px" }}
    >
      <div className="d-flex align-items-center justify-content-between">
        <span>{children}</span>
        {action}
      </div>
    </Alert>
  );
}

export default CenteredHalfAlert;
