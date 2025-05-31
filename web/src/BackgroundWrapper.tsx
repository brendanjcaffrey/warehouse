import { ReactNode } from "react";
import { useTheme } from "@mui/material";

interface BackgroundWrapperProps {
  children: ReactNode;
}

export function BackgroundWrapper({ children }: BackgroundWrapperProps) {
  const theme = useTheme();
  return (
    <div
      style={{
        backgroundColor: theme.palette.background.default,
        height: "100vh",
        overflow: "hidden",
      }}
    >
      {children}
    </div>
  );
}
