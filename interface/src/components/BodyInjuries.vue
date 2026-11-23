<script setup lang="ts">
// Silhouette façon HUD du jeu : 6 parties du corps séparées, la partie blessée colorée avec son tier
// (3 = mineure, 2 = modérée, 1 = grave), relié par un trait comme dans le jeu.
// Source : notifications « Injury Detected » du Game.log, lues par le service (injury.<partie> = tier).
import { computed } from 'vue'
import { has, num } from '@/telemetry'

interface Part {
  key: string
  label: string
  d: string // forme (grille 100 × 200, personnage vu de face : son bras droit est à gauche de l'écran)
  line: [number, number, number, number] // trait vers le chiffre
  tx: number // position du chiffre
  ty: number
}

// Jambes écartées et bras décollés du corps : chaque partie se lit séparément (grille 120 × 200)
const PARTS: Part[] = [
  { key: 'head', label: 'Head', d: 'M60 5a11 13 0 1 1 0 26a11 13 0 1 1 0-26z', line: [49, 18, 30, 18], tx: 24, ty: 18 },
  { key: 'torso', label: 'Torso', d: 'M46 36h28l3 60H43z', line: [49, 40, 37, 27], tx: 32, ty: 22 },
  { key: 'right_arm', label: 'Right arm', d: 'M44 38 34 42 13 90l6 4 21-42z', line: [14, 88, 3, 98], tx: -2, ty: 104 },
  { key: 'left_arm', label: 'Left arm', d: 'M76 38 86 42 107 90l-6 4-21-42z', line: [106, 88, 117, 98], tx: 122, ty: 104 },
  { key: 'right_leg', label: 'Right leg', d: 'M44 100h14l-19 96h-9z', line: [37, 160, 18, 160], tx: 11, ty: 160 },
  { key: 'left_leg', label: 'Left leg', d: 'M62 100h14l14 96h-9z', line: [83, 160, 102, 160], tx: 109, ty: 160 },
]

const tier = (p: Part): number | null => (has(`injury.${p.key}`) ? num(`injury.${p.key}`) : null)
const injured = computed(() => PARTS.filter((p) => tier(p) !== null))
const TIER_NAME: Record<number, string> = { 1: 'Severe', 2: 'Moderate', 3: 'Minor' }
</script>

<template>
  <div class="body">
    <svg viewBox="0 0 120 200" role="img" aria-label="Injuries">
      <g v-for="p in PARTS" :key="p.key" :class="tier(p) ? `t${tier(p)}` : ''">
        <path :d="p.d" class="part" />
        <template v-if="tier(p)">
          <line :x1="p.line[0]" :y1="p.line[1]" :x2="p.line[2]" :y2="p.line[3]" class="lead" />
          <text :x="p.tx" :y="p.ty" class="tier">{{ tier(p) }}</text>
        </template>
      </g>
    </svg>
    <ul class="list">
      <li v-if="!injured.length" class="none">No injury</li>
      <li v-for="p in injured" :key="p.key" :class="`t${tier(p)}`">
        <span>{{ p.label }}</span><b>{{ TIER_NAME[tier(p)!] }} · T{{ tier(p) }}</b>
      </li>
    </ul>
  </div>
</template>

<style scoped lang="scss">
.body {
  display: grid;
  justify-items: center;
  align-content: center; // centré dans la hauteur du panneau
  gap: 12px;
  height: 100%;
}

svg {
  width: auto;
  height: 230px;
  max-width: 100%;
  overflow: visible;
}

// Couleur par tier : 3 = mineure (ambre), 2 = modérée (orange), 1 = grave (rouge)
.t3 { --c: var(--amber); }
.t2 { --c: #f97316; }
.t1 { --c: var(--red); }

.part {
  fill: rgb(99 228 221 / 4%);
  stroke: var(--cyan);
  stroke-width: 1.6;
  stroke-linejoin: round;

  [class^='t'] > & {
    fill: var(--c);
    fill-opacity: 0.35;
    stroke: var(--c);
  }
}

.lead {
  stroke: var(--c);
  stroke-width: 1.5;
}

.tier {
  fill: var(--c);
  font: 700 18px var(--font-num);
  text-anchor: middle;
  dominant-baseline: central;
}

.list {
  display: grid;
  gap: 6px;
  margin: 0;
  padding: 0;
  list-style: none;

  li {
    display: flex;
    justify-content: center;
    align-items: baseline;
    gap: 8px;
    font-size: 13px;
  }

  b {
    @include numeric;
    color: var(--c);
    font-size: 12px;
    letter-spacing: 0.06em;
    text-transform: uppercase;
  }

  .none {
    @include label;
  }
}
</style>
