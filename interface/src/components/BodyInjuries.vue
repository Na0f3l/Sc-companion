<script setup lang="ts">
// Silhouette « radiographie » façon écran médical du jeu : corps translucide + squelette lumineux,
// 6 parties séparées ; la partie blessée prend la couleur de son tier
// (3 = mineure, 2 = modérée, 1 = grave), reliée à son chiffre par un trait comme dans le jeu.
// Source : notifications « Injury Detected » du Game.log, lues par le service (injury.<partie> = tier).
// SVG pur, tracés calculés une seule fois au chargement : aucun coût à l'exécution.
import { computed } from 'vue'
import { has, num } from '@/telemetry'

// Grille 120 × 240, personnage vu de face : son côté droit est à gauche de l'écran.
// Le côté gauche est obtenu par symétrie (x → 120 − x) ; tracés en coordonnées absolues uniquement.
const mirror = (d: string) => d.replace(/(-?[\d.]+) (-?[\d.]+)/g, (_, x, y) => `${+(120 - +x).toFixed(2)} ${y}`)
// Rotation d'un tracé autour d'une articulation (cx, cy), angle en degrés (positif = le bas part vers la gauche).
// Bras et jambes sont dessinés droits puis écartés ainsi, comme la posture de l'écran médical du jeu.
const rotate = (d: string, cx: number, cy: number, deg: number) => {
  const [c, s] = [Math.cos((deg * Math.PI) / 180), Math.sin((deg * Math.PI) / 180)]
  return d.replace(/(-?[\d.]+) (-?[\d.]+)/g, (_, x, y) => {
    const [dx, dy] = [+x - cx, +y - cy]
    return `${+(cx + dx * c - dy * s).toFixed(2)} ${+(cy + dx * s + dy * c).toFixed(2)}`
  })
}
const arm = (d: string) => rotate(d, 40, 44, 12) // pivot : l'épaule
const leg = (d: string) => rotate(d, 50, 118, 5) // pivot : la hanche

// --- Torse ---
const TORSO_SKIN =
  'M55 34C53 39 45 39 40 42C36 45 36 51 38 58C40 68 42 80 43 92C43 100 40 108 40 118L60 126L80 118' +
  'C80 108 77 100 77 92C78 80 80 68 82 58C84 51 84 45 80 42C75 39 67 39 65 34Z'
const RIB_W = [9, 12, 13.5, 14, 14, 13, 11.5]
const TORSO_HALF =
  'M58 44Q52 41 45 43' + // clavicule
  RIB_W.map((w, i) => {
    const y = +(47 + i * 3.6).toFixed(1)
    return `M58 ${y}Q${58 - w} ${y - 2} ${59 - w} ${y + 5}`
  }).join('') +
  'M58 104C52 99 45 100 44 106C43 112 49 116 54 120' + // aile iliaque
  'M53 112C50 113 50 117 53 118C56 118 56 113 53 112Z' // trou obturateur
const VERTEBRAE = Array.from({ length: 23 }, (_, i) => `M58.8 ${38 + i * 3}L61.2 ${38 + i * 3}`).join('')
const TORSO_BONES = TORSO_HALF + mirror(TORSO_HALF) + 'M60 44L60 66M60 36L60 105' + VERTEBRAE + 'M57 105L63 105L60 117Z'

// --- Tête ---
const HEAD_SKIN = 'M60 4C67 4 71 10 71 17C71 24 68 29 65 31L65 36L55 36L55 31C52 29 49 24 49 17C49 10 53 4 60 4Z'
const HEAD_BONES =
  'M60 7C66 7 69 12 69 18C69 22 67 24 66 26L66 29C64 32 56 32 54 29L54 26C53 24 51 22 51 18C51 12 54 7 60 7Z' +
  'M55 18.5a2.2 2 0 1 0 4.4 0a2.2 2 0 1 0-4.4 0ZM60.6 18.5a2.2 2 0 1 0 4.4 0a2.2 2 0 1 0-4.4 0Z' + // orbites
  'M60 21.5L59 24L61 24ZM56 27.5L64 27.5M60 32L60 37'

// --- Bras droit (gauche de l'écran) ---
const ARM_SKIN = arm(
  'M41 41C35 42 31 46 29 54L25 86L17 118C14 123 11 129 10 136C10 140 14 141 15 138L17 133L18 137' +
    'C19 139 21 138 21 135L22 121L30 88L36 64L39 56Z',
)
const ARM_BONES = arm(
  'M38 44Q41 41 44 43M38 46L28 86' + // épaule, humérus
    'M27 89L18 119M29.5 89.5L20.5 120' + // radius, cubitus
    'M18 122L13 135M19.5 122.5L15.5 138M21 122.5L18 137M17 121L11 131', // main
)

// --- Jambe droite ---
const LEG_SKIN = leg(
  'M41 116C39 130 41 150 43 170C42 185 42 205 44 224L39 232C39 234 52 234 52 232L50 224' +
    'C52 205 54 188 54 172C55 155 58 138 59 126Z',
)
const LEG_BONES = leg(
  'M50 119Q53 117 54 120M50 119L47 170' + // tête du fémur, fémur
    'M46 172Q48 170 50 172Q48 175 46 172Z' + // rotule
    'M48 176L48 222M45 178L45.5 220' + // tibia, péroné
    'M47 224L42 231M48 224L46 232M49 224L50 232', // pied
)

interface Part {
  key: string
  label: string
  skin: string
  bones: string
  line: [number, number, number, number] // trait vers le chiffre
  tx: number // position du chiffre
  ty: number
}

// Ordre = ordre de dessin (le torse d'abord, les membres par-dessus)
const PARTS: Part[] = [
  { key: 'torso', label: 'Torso', skin: TORSO_SKIN, bones: TORSO_BONES, line: [70, 52, 90, 30], tx: 96, ty: 26 },
  { key: 'right_arm', label: 'Right arm', skin: ARM_SKIN, bones: ARM_BONES, line: [-7, 131, -13, 142], tx: -16, ty: 150 },
  { key: 'left_arm', label: 'Left arm', skin: mirror(ARM_SKIN), bones: mirror(ARM_BONES), line: [127, 131, 133, 142], tx: 136, ty: 150 },
  { key: 'right_leg', label: 'Right leg', skin: LEG_SKIN, bones: LEG_BONES, line: [36, 191, 18, 191], tx: 11, ty: 191 },
  { key: 'left_leg', label: 'Left leg', skin: mirror(LEG_SKIN), bones: mirror(LEG_BONES), line: [84, 191, 102, 191], tx: 109, ty: 191 },
  { key: 'head', label: 'Head', skin: HEAD_SKIN, bones: HEAD_BONES, line: [49, 16, 30, 16], tx: 24, ty: 16 },
]

const tier = (p: Part): number | null => (has(`injury.${p.key}`) ? num(`injury.${p.key}`) : null)
const injured = computed(() => PARTS.filter((p) => tier(p) !== null))
const TIER_NAME: Record<number, string> = { 1: 'Severe', 2: 'Moderate', 3: 'Minor' }
</script>

<template>
  <div class="body">
    <svg viewBox="-12 0 144 240" role="img" aria-label="Injuries">
      <g v-for="p in PARTS" :key="p.key" :class="tier(p) ? `t${tier(p)}` : ''">
        <path :d="p.skin" class="skin" />
        <path :d="p.bones" class="bones" />
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
  height: 260px;
  max-width: 100%;
  overflow: visible;
  // Halo « hologramme » : un seul filtre sur tout le SVG, recalculé seulement quand il change
  filter: drop-shadow(0 0 2px rgb(99 228 221 / 45%));
}

// Couleur par tier : 3 = mineure (ambre), 2 = modérée (orange), 1 = grave (rouge)
.t3 { --c: var(--amber); }
.t2 { --c: #f97316; }
.t1 { --c: var(--red); }

.skin {
  fill: rgb(99 228 221 / 7%);
  stroke: rgb(99 228 221 / 45%);
  stroke-width: 0.8;
  stroke-linejoin: round;
}

.bones {
  fill: none;
  stroke: rgb(170 240 236 / 85%);
  stroke-width: 0.9;
  stroke-linecap: round;
  stroke-linejoin: round;
}

// Partie blessée : chair teintée, contour et os dans la couleur du tier
[class^='t'] > .skin {
  fill: var(--c);
  fill-opacity: 0.3;
  stroke: var(--c);
  stroke-opacity: 0.9;
}

[class^='t'] > .bones {
  stroke: var(--c);
}

.lead {
  stroke: var(--c);
  stroke-width: 1.2;
}

.tier {
  fill: var(--c);
  font: 700 16px var(--font-num);
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

@include phone {
  .body {
    gap: 6px;
  }

  svg {
    height: 190px;
  }
}
</style>
