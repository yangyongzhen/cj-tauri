import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';
import { viteSingleFile } from 'vite-plugin-singlefile';

// 与 ionic-music 同款两件事：
//   1) dev server 固定 127.0.0.1:5173（strictPort，端口被占直接报错不静默换）；
//   2) 产物是**单个** index.html（后端用 File.readFrom 读它）；hls.js 约 500KB 也一并内联。
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
