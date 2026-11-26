<script setup lang="ts">
// Écran d'attente (service injoignable, jeu non lancé, menu, chargement), dans le style des MFD.
// Un emblème façon radar : anneaux et graduations peints une fois, seul le balayage tourne
// (transform, géré par la carte graphique).
import { computed } from 'vue'

export type IdleKind = 'link' | 'offline' | 'menu' | 'loading' | 'notelemetry'

const props = defineProps<{ kind: IdleKind }>()
defineEmits<{ demo: [] }>()

const TEXT: Record<IdleKind, { code: string; title: string; sub: string; hint: string }> = {
  link: {
    code: 'ERR-LINK',
    title: 'No link',
    sub: 'Companion service unreachable',
    hint: 'Start the service, the screens reconnect on their own',
  },
  offline: {
    code: 'SYS-IDLE',
    title: 'Standby',
    sub: 'Star Citizen is not running',
    hint: 'Launch the game, the screens will come up automatically',
  },
  menu: {
    code: 'SYS-MENU',
    title: 'Main menu',
    sub: 'Waiting to join the Persistent Universe or Arena Commander',
    hint: 'Telemetry starts once your character is in game',
  },
  loading: {
    code: 'SYS-LOAD',
    title: 'Loading',
    sub: 'Waiting for your character to spawn',
    hint: 'Telemetry is live, data will appear in a moment',
  },
  // en jeu d'après le Game.log (chargement terminé), mais aucun flux de télémétrie (désactivée en 5.0)
  notelemetry: {
    code: 'TLM-NONE',
    title: 'No telemetry',
    sub: 'You are in game, but Star Citizen is not sending telemetry',
    hint: 'This game version has telemetry turned off. RAM tracking and session recording keep working',
  },
}
const t = computed(() => TEXT[props.kind])

// graduations de l'anneau extérieur (une toutes les 10°, plus longues tous les 30°)
const ticks = Array.from({ length: 36 }, (_, i) => {
  const a = (i * 10 * Math.PI) / 180
  const r1 = i % 3 === 0 ? 84 : 88
  return { x1: 100 + r1 * Math.sin(a), y1: 100 - r1 * Math.cos(a), x2: 100 + 92 * Math.sin(a), y2: 100 - 92 * Math.cos(a), major: i % 3 === 0 }
})
</script>

<template>
  <section class="idle" :class="`is-${kind}`">
    <svg class="emblem" viewBox="0 0 200 200" aria-hidden="true">
      <g class="static">
        <circle cx="100" cy="100" r="92" />
        <circle cx="100" cy="100" r="64" />
        <circle cx="100" cy="100" r="36" class="faint" />
        <line x1="100" y1="12" x2="100" y2="188" class="faint" />
        <line x1="12" y1="100" x2="188" y2="100" class="faint" />
        <line v-for="(k, i) in ticks" :key="i" :x1="k.x1" :y1="k.y1" :x2="k.x2" :y2="k.y2" :class="{ major: k.major }" />
      </g>
      <!-- balayage : secteur dégradé + ligne, tourne lentement -->
      <g class="sweep">
        <!-- traînée derrière le trait (sens inverse de la rotation) -->
        <path d="M100 100 L100 8 A92 92 0 0 0 35 35 Z" class="cone" />
        <line x1="100" y1="100" x2="100" y2="8" class="beam" />
      </g>
      <circle cx="100" cy="100" r="4" class="hub" />
    </svg>

    <div class="text">
      <span class="code">{{ t.code }}</span>
      <h2>{{ t.title }}</h2>
      <p class="sub">{{ t.sub }}</p>
      <p class="hint">{{ t.hint }}</p>
      <!-- voir les écrans sans le jeu : visiteurs, ou développement sans lancer SC -->
      <button type="button" class="demo" @click="$emit('demo')">Preview mode<span>See the screens with sample data</span></button>
    </div>
  </section>
</template>

<style scoped lang="scss">
.idle {
  --c: var(--cyan);
  display: flex;
  flex-wrap: wrap;
  justify-content: center;
  align-items: center;
  gap: 28px 40px;
  // centré verticalement dans la place entre l'en-tête et la bande mémoire : hauteur de l'écran moins
  // la marge du haut, l'en-tête, l'espace sous l'en-tête et la marge du bas de la page (~180 px, voir App.vue)
  min-height: calc(100vh - 180px);
  min-height: calc(100dvh - 180px);
  padding: 24px 0;

  &.is-link,
  &.is-notelemetry {
    --c: var(--amber);
  }
}

.emblem {
  width: min(220px, 50vw);
  height: auto;
}

.static {
  fill: none;
  stroke: var(--cyan-dim);
  stroke-width: 1;

  .faint {
    stroke-dasharray: 2 4;
    opacity: 0.6;
  }

  .major {
    stroke: var(--c);
  }
}

.sweep {
  transform-origin: 100px 100px;
  animation: spin 6s linear infinite;
}

// Menu : balayage plus lent ; service injoignable ou jeu sans télémétrie : pas de balayage (rien n'arrivera)
.is-menu .sweep {
  animation-duration: 12s;
}

.is-link .sweep,
.is-notelemetry .sweep {
  display: none;
}

.cone {
  fill: var(--c);
  opacity: 0.12;
}

.beam {
  stroke: var(--c);
  stroke-width: 1.5;
}

.hub {
  fill: var(--c);
}

@keyframes spin {
  to {
    transform: rotate(360deg);
  }
}

.text {
  display: grid;
  gap: 6px;
  max-width: 36ch;
}

.code {
  @include numeric;
  color: var(--cyan-dim);
  font-size: 11px;
  letter-spacing: 0.3em;
}

h2 {
  @include numeric;
  margin: 0;
  color: var(--c);
  font-size: clamp(28px, 6vw, 44px);
  font-weight: 600;
  letter-spacing: 0.18em;
  text-transform: uppercase;
}

.sub {
  margin: 0;
  color: var(--text);
  font-size: 14px;
  letter-spacing: 0.04em;
}

.hint {
  @include label;
  margin: 6px 0 0;
  padding-top: 8px;
  border-top: 1px solid var(--line);
  font-size: 10px;
  line-height: 1.6;
}

.demo {
  @include bevel(8px);
  @include bevel-edges(8px);
  position: relative;
  justify-self: start;
  display: grid;
  gap: 2px;
  margin-top: 10px;
  padding: 8px 16px;
  border: 1px solid var(--cyan-dim);
  background: var(--panel);
  color: var(--cyan);
  font: 600 12px var(--font-num);
  letter-spacing: 0.16em;
  text-align: left;
  text-transform: uppercase;
  cursor: pointer;

  span {
    color: var(--muted);
    font: 400 10px var(--font-ui);
    letter-spacing: 0.06em;
    text-transform: none;
  }

  // survol en jaune, comme les autres boutons d'action (onglets, lien SPViewer)
  &:hover {
    border-color: var(--amber);
    color: var(--amber);
  }

  &:focus-visible {
    outline: 2px solid var(--amber);
    outline-offset: 2px;
  }
}
</style>
