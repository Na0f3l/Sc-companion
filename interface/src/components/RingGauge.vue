<script setup lang="ts">
// Jauge circulaire façon HUD du jeu : un anneau qui se remplit, un picto au centre, le % dessous.
// Une seule propriété change à chaque mise à jour (stroke-dasharray) : très peu de calcul.
import { computed } from 'vue'

const props = withDefaults(
  defineProps<{
    value: number // 0 → 1
    icon: 'health' | 'hunger' | 'thirst'
    label: string
    alert?: 'low' | 'high' | 'none'
    warnAt?: number // seuil orange (sous ce seuil en mode low, au-dessus en mode high)
    critAt?: number // seuil rouge
    cap?: number // 0 → 1 : maximum atteignable (vie max baissée par les blessures), le reste est barré
  }>(),
  { alert: 'low', warnAt: undefined, critAt: undefined, cap: 1 },
)
// part inatteignable, de cap à 100 % : trait nul, espace jusqu'à cap, trait jusqu'au bout
const capPct = computed(() => Math.round(Math.min(1, Math.max(0, props.cap)) * 100))
const lostDash = computed(() => `0 ${capPct.value} ${100 - capPct.value} 100`)

// Arrondi vers le bas, comme le jeu (82,86 → 82 en jeu, pas 83). Le 1e-6 évite qu'une valeur
// exacte mal représentée en flottant (0,82 × 100 = 81,999…) tombe à l'entier du dessous.
const pct = computed(() => Math.floor(Math.min(1, Math.max(0, props.value)) * 100 + 1e-6))
const dash = computed(() => `${pct.value} 100`)
const level = computed(() => {
  const v = props.value
  if (props.alert === 'low') {
    const warn = props.warnAt ?? 0.3
    const crit = props.critAt ?? 0.15
    return v < crit ? 'crit' : v < warn ? 'warn' : 'ok'
  }
  if (props.alert === 'high') {
    const warn = props.warnAt ?? 0.55
    const crit = props.critAt ?? 0.8
    return v > crit ? 'crit' : v > warn ? 'warn' : 'ok'
  }
  return 'ok'
})
</script>

<template>
  <figure class="ring" :class="`is-${level}`" role="meter" :aria-label="label" :aria-valuenow="pct" aria-valuemin="0" aria-valuemax="100">
    <svg viewBox="0 0 64 64" aria-hidden="true">
      <circle class="track" cx="32" cy="32" r="26" />
      <!-- pathLength=100 : la longueur de l'anneau vaut 100, donc dasharray = pourcentage -->
      <circle v-if="capPct < 100" class="lost" cx="32" cy="32" r="26" pathLength="100" :stroke-dasharray="lostDash" />
      <circle class="fill" cx="32" cy="32" r="26" pathLength="100" :stroke-dasharray="dash" />
      <line class="tick" x1="32" y1="3" x2="32" y2="9" />
      <g class="icon">
        <!-- pictos provisoires, à remplacer par ceux du jeu -->
        <path v-if="icon === 'health'" d="M32 22v20M22 32h20" />
        <path v-else-if="icon === 'thirst'" d="M32 21c-5 7-8 11-8 15a8 8 0 0 0 16 0c0-4-3-8-8-15z" />
        <path v-else d="M26 21v8a3 3 0 0 0 6 0v-8M29 21v22M37 21c-2 2-3 6-3 10h3v12" />
      </g>
    </svg>
    <figcaption>
      <span class="pct">{{ pct }}%</span>
      <span class="name">{{ label }}</span>
    </figcaption>
  </figure>
</template>

<style scoped lang="scss">
.ring {
  --c: var(--cyan);
  display: grid;
  justify-items: center;
  gap: 4px;
  margin: 0;
  padding: 10px 6px 8px;
  border: 1px solid var(--line);
  background: rgb(99 228 221 / 3%);
  @include bevel(6px);
  @include bevel-edges(6px);
  position: relative;

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
  max-width: 68px;
  height: auto;
}

circle {
  fill: none;
  stroke-width: 4;
}

.track {
  stroke: var(--off);
}

// vie max perdue (blessures) : rouge sombre, comme la jauge du jeu
.lost {
  stroke: var(--red);
  stroke-opacity: 0.35;
  transform: rotate(-90deg);
  transform-origin: 32px 32px;
}

.fill {
  stroke: var(--c);
  transform: rotate(-90deg); // départ en haut
  transform-origin: 32px 32px;
}

.tick {
  stroke: var(--amber);
  stroke-width: 2;
}

.icon path {
  fill: none;
  stroke: var(--c);
  stroke-width: 3;
  stroke-linecap: round;
  stroke-linejoin: round;
}

figcaption {
  display: grid;
  justify-items: center;
  gap: 2px;
}

.pct {
  @include numeric;
  color: var(--text);
  font-size: 18px;
  font-weight: 600;
}

.name {
  @include label;
  font-size: 10px;
}

@include phone {
  .ring {
    gap: 2px;
    padding: 6px 4px 5px;
  }

  svg {
    max-width: 44px;
  }

  .pct {
    font-size: 15px;
  }

  .name {
    font-size: 9px;
  }
}
</style>
