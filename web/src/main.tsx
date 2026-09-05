import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "bootstrap/dist/css/bootstrap.min.css";
import App from "./App";
import { watchColorMode } from "./theme";
import { applyDevChrome, isDevMode } from "./DevMode";

watchColorMode();

if (isDevMode()) applyDevChrome(document);

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>
);
