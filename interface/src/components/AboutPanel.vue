<script setup lang="ts">
// Fenêtre « About » (menu) : ce que fait l'appli, crédits (schéma de télémétrie, données vaisseaux, sons, polices,
// bibliothèques) et mentions légales (licence MIT, projet de fan non officiel, données restées sur le PC).
// Les licences des bibliothèques ont été relevées dans leur package.json (2026-11-25).
import { ref } from 'vue'

const dlg = ref<HTMLDialogElement | null>(null)
const open = () => dlg.value?.showModal()
defineExpose({ open })

// clic sur le fond (en dehors de la boîte) : fermer
function onClick(e: MouseEvent): void {
  if (e.target === dlg.value) dlg.value?.close()
}

const REPO = 'https://github.com/Na0f3l/Sc-companion'
const VERSION = __APP_VERSION__

const CREDITS = [
  { what: 'Telemetry schema', who: 'Sokren — sc-telemetry-deck', url: 'https://github.com/Sokren/sc-telemetry-deck', note: 'pioneering work on the game\'s telemetry interface (the schema itself is read from your game install)' },
  { what: 'Ship data', who: 'Star Citizen Wiki API', url: 'https://api.star-citizen.wiki', note: 'names, speeds, rotation rates, fuel' },
  { what: 'Ship accelerations', who: 'SPViewer', url: 'https://www.spviewer.eu', note: 'community-measured G values' },
  { what: 'Critical alert sound', who: 'Lyubomir Ikonomov — Freesound', url: 'https://freesound.org/s/787777/', note: '“warning”' },
  { what: 'Warning alert sound', who: 'Mixkit', url: 'https://mixkit.co/', note: '“Mechanical gas release alert”' },
  { what: 'Fonts', who: 'Oxanium, Chakra Petch', url: 'https://fontsource.org', note: 'SIL Open Font License 1.1' },
]

const LIBS = [
  { name: 'Vue', license: 'MIT', url: 'https://vuejs.org' },
  { name: 'ws', license: 'MIT', url: 'https://github.com/websockets/ws' },
  { name: 'gRPC for Node.js', license: 'Apache-2.0', url: 'https://github.com/grpc/grpc-node' },
  { name: 'Koffi', license: 'MIT', url: 'https://koffi.dev' },
  { name: 'qrcode-generator', license: 'MIT', url: 'https://github.com/kazuhikoarase/qrcode-generator' },
]
</script>

<template>
  <!-- la boîte suit la taille de la fenêtre ; le contenu défile dans le cadre, titre et croix restent en haut -->
  <dialog ref="dlg" class="box" aria-labelledby="ab-title" @click="onClick">
    <div class="frame">
    <header>
      <h2 id="ab-title">About SC Companion <small class="ver">v{{ VERSION }}</small></h2>
      <button type="button" class="x" aria-label="Close" @click="dlg?.close()">✕</button>
    </header>

    <p class="lead">
      A second-screen companion for Star Citizen, on your PC or your phone: flight and character HUD from the game's
      telemetry, alerts (crash, collision, missiles, vitals…), a memory monitor that catches RAM leaks, a timeline of
      game events, and recorded play sessions you can review afterwards.
    </p>

    <h3>Credits</h3>
    <ul class="credits">
      <li v-for="c in CREDITS" :key="c.what">
        <span class="k">{{ c.what }}</span>
        <span>
          <a :href="c.url" target="_blank" rel="noopener noreferrer">{{ c.who }}</a>
          <small> · {{ c.note }}</small>
        </span>
      </li>
    </ul>
    <p class="libs">
      Built with
      <template v-for="(l, i) in LIBS" :key="l.name">
        <a :href="l.url" target="_blank" rel="noopener noreferrer">{{ l.name }}</a> <small>({{ l.license }})</small><template v-if="i < LIBS.length - 1">, </template>
      </template>.
    </p>

    <h3>Legal</h3>
    <ul class="legal">
      <li>
        <b>Free and open source</b> — MIT License, © 2026 Na0f3l.
        <a :href="REPO" target="_blank" rel="noopener noreferrer">Source code on GitHub</a>.
        Third-party material above keeps its own license.
      </li>
      <li>
        <b>Unofficial fan project</b>, not affiliated with or endorsed by Cloud Imperium Games. Star Citizen®,
        Roberts Space Industries® and Cloud Imperium® are trademarks of Cloud Imperium Rights LLC.
      </li>
      <li>
        <b>Read-only.</b> The app only reads the game's telemetry interface, its log file and Windows performance
        counters. It never modifies the game, its files or its memory.
      </li>
      <li>
        <b>Your data stays on your PC.</b> Nothing is sent anywhere. The only requests to the internet fetch public
        ship data from the Star Citizen Wiki and SPViewer.
      </li>
      <li>Provided “as is”, without warranty of any kind.</li>
    </ul>
    </div>
  </dialog>
</template>

<style scoped lang="scss">
a:focus-visible,
button:focus-visible {
  outline: 2px solid var(--amber);
  outline-offset: 1px;
}

// boîte transparente à la taille de la fenêtre (jamais plus haute que l'écran)
.box {
  width: min(560px, calc(100vw - 32px));
  max-width: none;
  max-height: calc(100vh - 32px);
  padding: 0;
  border: 0;
  background: none;
  color: var(--text);
  overflow: visible;

  &::backdrop {
    background: rgb(0 0 0 / 65%);
  }
}

// cadre biseauté qui défile quand le contenu dépasse (barre fine du thème, styles/base.scss)
.frame {
  max-height: calc(100vh - 32px);
  padding: 0 18px 18px;
  overflow-y: auto;
  overscroll-behavior: contain;
  border: 1px solid var(--cyan-dim);
  @include bevel-edges-bg(10px, var(--cyan-dim), var(--panel));
  @include bevel(10px);
}

// titre et croix collés en haut pendant le défilement
header {
  position: sticky;
  top: 0;
  z-index: 1;
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin: 0 -18px 8px;
  padding: 14px 18px 8px;
  background: var(--panel);
}

h2 {
  margin: 0;
  @include label;
  color: var(--cyan);
  font-size: 12px;

  .ver {
    margin-left: 6px;
    color: var(--muted);
    font-size: 10px;
  }
}

h3 {
  @include label;
  margin: 14px 0 6px;
  color: var(--cyan);
  font-size: 10px;
}

.x {
  padding: 2px 6px;
  border: 0;
  background: none;
  color: var(--muted);
  cursor: pointer;

  &:hover {
    color: var(--cyan);
  }
}

p,
li {
  font: 500 12px/1.5 var(--font-ui);
  letter-spacing: 0.02em;
}

p {
  margin: 0;
}

.lead {
  color: var(--text);
}

a {
  color: var(--cyan);
  text-decoration: none;

  &:hover {
    text-decoration: underline;
  }
}

small {
  color: var(--muted);
}

ul {
  margin: 0;
  padding: 0;
  list-style: none;
}

.credits li {
  display: grid;
  grid-template-columns: 9.5em 1fr;
  gap: 2px 10px;
  padding: 3px 0;
  border-bottom: 1px solid var(--off);

  @include phone {
    grid-template-columns: 1fr;
  }
}

.k {
  @include label;
  align-self: center;
  font-size: 10px;
}

.libs {
  margin-top: 8px;
  color: var(--muted);
}

.legal li {
  position: relative;
  padding: 3px 0 3px 14px;
  color: var(--muted);

  &::before {
    content: '';
    position: absolute;
    top: 0.85em;
    left: 2px;
    width: 5px;
    height: 1px;
    background: var(--cyan-dim);
  }

  b {
    color: var(--text);
    font-weight: 600;
  }
}
</style>
