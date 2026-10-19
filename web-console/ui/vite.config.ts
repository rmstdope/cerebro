import path from "node:path";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: { alias: { "@": path.resolve(__dirname, "./src") } },
  server: {
    proxy: {
      // The service's port; the browser suite sets it to the block it reserved.
      "/api": `http://127.0.0.1:${process.env.CEREBRO_WEB_PORT || 7171}`,
    },
  },
});
