import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { viteSingleFile } from 'vite-plugin-singlefile';

// 两件事很重要：
//   1) dev server 固定 127.0.0.1:5173 —— cj-tauri dev 就是按这个地址探活并注入 CJ_TAURI_DEV_URL 的；
//      strictPort 让它端口被占时直接报错，而不是悄悄换一个导致应用连不上。
//   2) 构建产物必须是**单个** index.html —— 后端用 File.readFrom 读它，与 app 模板的单文件模式一致；
//      assetsInlineLimit 调大是为了让图片等资源也内联进 HTML。
export default defineConfig({
  plugins: [react(), viteSingleFile()],
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
