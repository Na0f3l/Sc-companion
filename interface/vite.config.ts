import { fileURLToPath, URL } from 'node:url'

import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import vueDevTools from 'vite-plugin-vue-devtools'

// https://vite.dev/config/
export default defineConfig({
  plugins: [
    vue(),
    vueDevTools(), // outil de debug, actif uniquement en développement (npm run dev)
  ],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  css: {
    preprocessorOptions: {
      // les mixins SCSS sont disponibles dans chaque <style lang="scss"> sans import manuel
      scss: { additionalData: '@use "@/styles/mixins" as *;\n' },
    },
  },
  server: {
    host: true, // accessible depuis le téléphone sur le Wi-Fi local (http://<ip-du-pc>:5173)
    // /ws est relayé vers le service : la page parle toujours à sa propre adresse, PC comme téléphone
    proxy: { '/ws': { target: 'ws://localhost:2950', ws: true } },
  },
})
