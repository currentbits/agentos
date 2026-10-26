/// <reference types="vitest/config" />
import { defineConfig } from 'vite';

export default defineConfig({
  build: { outDir: 'dist', target: 'es2023', chunkSizeWarningLimit: 1000 },
  server: { proxy: { '/api': { target: 'http://127.0.0.1:7070', ws: true }, '/novnc': 'http://127.0.0.1:7070' } },
  test: { environment: 'jsdom' },
});
