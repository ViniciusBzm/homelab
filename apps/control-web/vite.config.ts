import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite";

// Dev: hot reload em 127.0.0.1:5173 com /api encaminhado para a API local (fixtures + servicos simulados).
export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    host: "127.0.0.1",
    port: 5173,
    strictPort: true,
    proxy: { "/api": { target: `http://127.0.0.1:${process.env.HL_CONTROL_PORT ?? "8088"}`, changeOrigin: false } },
  },
  build: { outDir: "dist", emptyOutDir: true, sourcemap: false, assetsInlineLimit: 0 },
});
