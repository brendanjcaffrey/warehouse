import { ReactNode } from "react";

interface BackgroundWrapperProps {
  children: ReactNode;
}

export function BackgroundWrapper({ children }: BackgroundWrapperProps) {
  return (
    <div
      style={{
        backgroundColor: "var(--bs-body-bg)",
        color: "var(--bs-body-color)",
        height: "100vh",
        overflow: "hidden",
      }}
    >
      {children}
    </div>
  );
}
