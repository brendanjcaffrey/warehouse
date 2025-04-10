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
        name: "Music Streamer",
        short_name: "Streamer",
        description: "Music library streamer",
        theme_color: "#ffffff",
        icons: [
          {
            src: "favicon/web-app-manifest-192x192.png",
            sizes: "192x192",
            type: "image/png",
          },
          {
            src: "favicon/web-app-manifest-512x512.png",
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
    port: 5568,
    proxy: {
      "/api": "http://localhost:5567",
      "/tracks": "http://localhost:5567",
      "/download": "http://localhost:5567",
      "/artwork": "http://localhost:5567",
    },
  },
};

export default defineConfig(config);
