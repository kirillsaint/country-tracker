import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// Админка живёт по /admin на домене API; в разработке запросы к API проксируются на локальный бэкенд
export default defineConfig({
  base: "/admin/",
  plugins: [react(), tailwindcss()],
  server: {
    port: 5173,
    proxy: { "/admin/api": "http://localhost:3000" },
  },
});
