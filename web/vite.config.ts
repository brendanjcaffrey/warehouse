import { defineConfig } from "vite";
import react from "@vitejs/plugin-react-swc";

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  build: {
    outDir: "../public",
    emptyOutDir: true,
  },
  test: {
  },
  server: {
    port: 5568,
    proxy: {
      "/api": "http://localhost:5567",
      "/tracks": "http://localhost:5567",
      "/download": "http://localhost:5567",
      "/artwork": "http://localhost:5567",
    },
  },
});
