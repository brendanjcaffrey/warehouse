import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react-swc";
import { playwright } from "@vitest/browser-playwright";

// runs the reveal tests in a real chromium so react-window virtualization,
// layout and scrolling behave for real, covering what the jsdom suite can't.
// kept separate from vite.config.ts so `rake web:vitest` stays fast and needs
// no browser installed
export default defineConfig({
  plugins: [react()],
  test: {
    include: ["tests/**/*.browser.test.tsx"],
    browser: {
      enabled: true,
      provider: playwright(),
      headless: true,
      instances: [{ browser: "chromium" }],
    },
  },
});
