import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';
import { viteSingleFile } from 'vite-plugin-singlefile';

// 两件事：
//   1) dev server 固定 127.0.0.1:5173 —— cj-tauri dev 按这个地址探活并注入 CJ_TAURI_DEV_URL；
//   2) 构建产物必须是单个 index.html —— 骨架 launcher 用 File.readFrom 读它，
//      assetsInlineLimit 调大让图标等资源内联进 HTML（Ionic 图标走 SVG 内联，不占体积）。
export default defineConfig({
  plugins: [vue(), viteSingleFile()],
  base: './',
  server: {
    host: '127.0.0.1',
    port: 5173,
    strictPort: true
  },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    cssCodeSplit: false,
    assetsInlineLimit: 104857600
  }
});
