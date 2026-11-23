<script setup lang="ts">
// Indicateur de G façon HUD du jeu : trièdre en perspective (haut/bas, gauche/droite, avant/arrière),
// une barre rouge par axe proportionnelle aux G sur cet axe, la charge totale et la vitesse à droite.
//
// La télémétrie actuelle ne donne que la charge totale : sans `axes`, les axes restent au repos.
// Si on trouve un jour la répartition (x latéral, y vertical, z longitudinal, en G signés), il suffira de la passer.
import { computed } from 'vue'

const props = withDefaults(
  defineProps<{
    g: number // charge totale
    limit?: number // limite avant voile noir / rouge
    speed?: number
    axes?: { x: number; y: number; z: number } | null
    scale?: number // G pour une barre pleine
  }>(),
  { limit: 9, speed: 0, axes: null, scale: 10 },
)

// Directions à l'écran (perspective) : x → droite, y → haut, z (vers l'arrière) → bas-droite
const C = 50
const L = 38
const DIR = { x: [1, 0], y: [0, -1], z: [0.82, 0.42] } as const

const bars = computed(() => {
  if (!props.axes) return []
  return (['x', 'y', 'z'] as const)
    .map((k) => {
      const v = Math.max(-1, Math.min(1, props.axes![k] / props.scale))
      const [dx, dy] = DIR[k]
      return { k, x2: C + dx * L * v, y2: C + dy * L * v, on: Math.abs(v) > 0.01 }
    })
    .filter((b) => b.on)
})

const level = computed(() => {
  const r = props.g / (props.limit || 1)
  return r > 0.8 ? 'crit' : r > 0.55 ? 'warn' : 'ok'
})
</script>

<template>
  <div class="gmeter" :class="`is-${level}`">
    <svg viewBox="0 0 100 100" aria-hidden="true">
      <!-- axes en pointillés et leurs extrémités -->
      <g class="axes">
        <line :x1="C" :y1="C - L" :x2="C" :y2="C + L" />
        <line :x1="C - L" :y1="C" :x2="C + L" :y2="C" />
        <line :x1="C - DIR.z[0] * L" :y1="C - DIR.z[1] * L" :x2="C + DIR.z[0] * L" :y2="C + DIR.z[1] * L" />
      </g>
      <g class="ends">
        <circle :cx="C" :cy="C - L" r="3" />
        <circle :cx="C" :cy="C + L" r="3" />
        <circle :cx="C - L" :cy="C" r="3" />
        <circle :cx="C + L" :cy="C" r="3" />
        <circle :cx="C - DIR.z[0] * L" :cy="C - DIR.z[1] * L" r="2" />
        <circle :cx="C + DIR.z[0] * L" :cy="C + DIR.z[1] * L" r="4" class="near" />
      </g>
      <!-- barres rouges par axe -->
      <line v-for="b in bars" :key="b.k" class="bar" :x1="C" :y1="C" :x2="b.x2" :y2="b.y2" />
      <circle :cx="C" :cy="C" r="4.5" class="hub" />
    </svg>
    <div class="readout">
      <span class="g">{{ g.toFixed(1) }}<small>G</small></span>
      <span class="speed">{{ speed.toFixed(1) }}</span>
    </div>
  </div>
</template>

<style scoped lang="scss">
.gmeter {
  --c: var(--cyan);
  display: grid;
  grid-template-columns: minmax(0, 96px) auto;
  align-items: center;
  justify-content: center;
  gap: 14px;

  &.is-warn {
    --c: var(--amber);
  }

  &.is-crit {
    --c: var(--red);
  }
}

svg {
  display: block;
  width: 100%;
  height: auto;
}

.axes line {
  stroke: var(--cyan-dim);
  stroke-width: 1;
  stroke-dasharray: 1.5 2.5;
}

.ends circle {
  fill: none;
  stroke: var(--c);
  stroke-width: 1.4;

  &.near {
    fill: var(--c);
  }
}

.bar {
  stroke: var(--red);
  stroke-width: 3;
  stroke-linecap: round;
}

.hub {
  fill: var(--text);
}

.readout {
  display: grid;
  justify-items: center;
}

.g {
  @include numeric;
  padding-bottom: 3px;
  border-bottom: 1px solid var(--c);
  color: var(--c);
  font-size: 26px;
  font-weight: 600;
  letter-spacing: 0.08em;

  small {
    margin-left: 6px;
    font-size: 16px;
  }
}

.speed {
  @include numeric;
  padding-top: 3px;
  color: var(--c);
  font-size: 13px;
  letter-spacing: 0.08em;
}
</style>
