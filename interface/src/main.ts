import { createApp } from 'vue'
import App from './App.vue'

// Polices embarquées (pas de requête vers Google) : seulement l'alphabet latin et les graisses utilisées.
import '@fontsource/oxanium/latin-400.css'
import '@fontsource/oxanium/latin-500.css'
import '@fontsource/oxanium/latin-600.css'
import '@fontsource/chakra-petch/latin-400.css'
import '@fontsource/chakra-petch/latin-500.css'
import '@fontsource/chakra-petch/latin-600.css'
import './styles/base.scss'

createApp(App).mount('#app')
