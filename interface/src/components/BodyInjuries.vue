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

const PARTS: Part[] = [
  { key: 'head', label: 'Head', d: 'M50 6a10 12 0 1 1 0 24a10 12 0 1 1 0-24z', line: [40, 18, 22, 18], tx: 16, ty: 18 },
  { key: 'torso', label: 'Torso', d: 'M37 34h26l3 58H34z', line: [36, 62, 14, 62], tx: 8, ty: 62 },
  { key: 'right_arm', label: 'Right arm', d: 'M33 36l-8 4-6 56 6 2 7-46z', line: [21, 86, 9, 98], tx: 5, ty: 106 },
  { key: 'left_arm', label: 'Left arm', d: 'M67 36l8 4 6 56-6 2-7-46z', line: [79, 86, 91, 98], tx: 95, ty: 106 },
  { key: 'right_leg', label: 'Right leg', d: 'M35 96h14l-2 90h-8z', line: [38, 150, 20, 150], tx: 14, ty: 150 },
  { key: 'left_leg', label: 'Left leg', d: 'M51 96h14l-4 90h-8z', line: [62, 150, 80, 150], tx: 86, ty: 150 },
]

const tier = (p: Part): number | null => (has(`injury.${p.key}`) ? num(`injury.${p.key}`) : null)
const injured = computed(() => PARTS.filter((p) => tier(p) !== null))
const TIER_NAME: Record<number, string> = { 1: 'Severe', 2: 'Moderate', 3: 'Minor' }
</script>

<template>
  <div class="body">
    <svg viewBox="-4 0 108 196" role="img" aria-label="Injuries">
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
  grid-template-columns: auto 1fr;
  align-items: center;
  gap: 14px;
}

svg {
  width: 92px;
  height: auto;
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
    justify-content: space-between;
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
