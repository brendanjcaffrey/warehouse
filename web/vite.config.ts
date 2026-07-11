import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react-swc";
import { VitePWA } from "vite-plugin-pwa";

// https://vite.dev/config/
export default defineConfig({
  plugins: [
    react(),
    VitePWA({
      registerType: "autoUpdate",
      workbox: {
        globPatterns: ["**/*.{js,css,html,ico,png,svg}"],
      },
      manifest: {
        name: "Warehouse",
        short_name: "Warehouse",
        description: "Music library streamer",
        theme_color: "#ffffff",
        icons: [
          {
            src: "favicon/android-chrome-192x192.png",
            sizes: "192x192",
            type: "image/png",
          },
          {
            src: "favicon/android-chrome-512x512.png",
            sizes: "512x512",
            type: "image/png",
          },
        ],
      },
    }),
  ],
  build: {
    outDir: "../public",
    emptyOutDir: true,
  },
  test: {
    environment: "jsdom",
    // browser-mode tests run under their own config so the fast jsdom suite
    // isn't gated on a playwright browser being installed
    exclude: ["node_modules/**", "tests/**/*.browser.test.tsx"],
  },
  server: {
    port: 20602,
    proxy: {
      "/api": "http://localhost:20601",
      "/music": "http://localhost:20601",
      "/download": "http://localhost:20601",
      "/artwork": "http://localhost:20601",
    },
  },
});
