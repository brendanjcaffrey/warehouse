import { defineConfig } from "vite";
import type { InlineConfig } from "vitest";
import type { UserConfig } from "vite";
import react from "@vitejs/plugin-react-swc";
import { VitePWA } from "vite-plugin-pwa";

// https://vite.dev/config/
type ViteConfig = UserConfig & { test: InlineConfig };
const config: ViteConfig = {
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
  },
  server: {
    port: 20602,
    proxy: {
      "/api": "http://localhost:20601",
      "/tracks": "http://localhost:20601",
      "/download": "http://localhost:20601",
      "/artwork": "http://localhost:20601",
    },
  },
};

export default defineConfig(config);
