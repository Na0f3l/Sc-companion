<script setup lang="ts">
// Bande de cap. Les graduations sont générées une fois ; seul un translateX bouge
// (propriété gérée par la carte graphique, sans recalcul de la mise en page).
//
// Lissage : une transition de 200 ms (= intervalle entre deux mises à jour du service)
// relie chaque position à la suivante, d'où un défilement continu sans rafraîchir plus souvent.
//
// Passage 359° → 0° : on suit l'angle « déroulé » (359 → 361 au lieu de 359 → 1) pour que la bande
// tourne de 2° et pas de 358° en arrière. Quand l'angle déroulé sort de la bande, on le recale
// de 360° sans transition (même graduation affichée, donc invisible).
//
// Verrouillage du cap (cadenas à droite) : un clic fige le cap actuel, marqué en rouge sur la bande ; un second
// clic le libère. Écart (plus court chemin, donc 358° → 3° = 5°) : ≤ 5° normal, 5 à 10° orange, au-delà rouge,
// avec des chevrons qui clignotent du côté vers lequel tourner. Gardé tant qu'on ne le libère pas.
import { computed, nextTick, ref, watch } from 'vue'

const props = defineProps<{ heading: number }>()

const PX_PER_DEG = 3
const WARN_DEG = 5
const CRIT_DEG = 10
const CARDINAL: Record<number, string> = { 0: 'N', 90: 'E', 180: 'S', 270: 'O' }
// bande de -180° à 540° : on peut afficher n'importe quel angle déroulé entre -90 et 450
const cells = Array.from({ length: 145 }, (_, i) => {
  const d = (((-180 + i * 5) % 360) + 360) % 360
  const major = d % 30 === 0
  return { major, label: major ? (CARDINAL[d] ?? String(d)) : '' }
})

const shown = ref(props.heading) // angle déroulé
const animate = ref(true)

watch(
  () => props.heading,
  async (h) => {
    const delta = ((((h - shown.value) % 360) + 540) % 360) - 180 // plus court chemin, entre -180 et 180
    let next = shown.value + delta
    if (next < -90 || next > 450) {
      const wrap = next < -90 ? 360 : -360
      animate.value = false
      shown.value += wrap // recalage instantané, même image à l'écran
      await nextTick()
      requestAnimationFrame(() => {
        animate.value = true
        shown.value = next + wrap
      })
      return
    }
    shown.value = next
  },
)

const style = computed(() => ({
  transform: `translateX(${-(shown.value + 180) * PX_PER_DEG}px)`,
  transition: animate.value ? 'transform 200ms linear' : 'none',
}))

// ---- Cap verrouillé ----------------------------------------------------------------------------
const norm = (d: number) => ((Math.round(d) % 360) + 360) % 360
const locked = ref<number | null>(null)
function toggleLock(): void {
  locked.value = locked.value === null ? norm(props.heading) : null
}

// écart signé, entre -180 et 180 : positif = on est trop à droite (il faut tourner à gauche)
const deviation = computed(() => (locked.value === null ? 0 : ((((props.heading - locked.value) % 360) + 540) % 360) - 180))
const level = computed(() => {
  if (locked.value === null) return ''
  const a = Math.abs(deviation.value)
  return a > CRIT_DEG ? 'crit' : a > WARN_DEG ? 'warn' : 'ok'
})
const turn = computed(() => (level.value === 'warn' || level.value === 'crit' ? (deviation.value > 0 ? 'left' : 'right') : null))

// marqueur sur la bande : le cap verrouillé et ses doubles à ±360° (la bande va de -180° à 540°)
const marks = computed(() => (locked.value === null ? [] : [locked.value - 360, locked.value, locked.value + 360].map((a) => (a + 180) * PX_PER_DEG)))

const fmt = (d: number) => String(norm(d)).padStart(3, '0')
const fmtDev = computed(() => {
  const d = Math.round(deviation.value)
  return `${d > 0 ? '+' : d < 0 ? '−' : '±'}${Math.abs(d)}°`
})
</script>

<template>
  <div class="tape" :class="level && `is-${level}`">
    <div class="ruler" aria-hidden="true">
      <div class="strip" :style="style">
        <div v-for="(c, i) in cells" :key="i" class="c" :class="{ maj: c.major }">
          <span v-if="c.label">{{ c.label }}</span>
        </div>
        <i v-for="x in marks" :key="x" class="bug" :style="{ left: `${x}px` }" />
      </div>
      <!-- chevrons collés au repère central, du côté vers lequel tourner pour revenir au cap -->
      <span v-if="turn === 'left'" class="turn left">‹‹‹</span>
      <span v-if="turn === 'right'" class="turn right">›››</span>
    </div>

    <div class="lock">
      <span v-if="locked !== null" class="hold" :title="`Locked heading ${fmt(locked)}°, deviation ${fmtDev}`">
        <b>{{ fmt(locked) }}°</b><small>{{ fmtDev }}</small>
      </span>
      <button
        type="button"
        class="padlock"
        :class="{ on: locked !== null }"
        :aria-pressed="locked !== null"
        :title="locked !== null ? 'Release heading' : 'Lock current heading'"
        :aria-label="locked !== null ? 'Release heading' : 'Lock current heading'"
        @click="toggleLock"
      >
        <svg viewBox="0 0 16 16" aria-hidden="true">
          <rect x="3" y="7" width="10" height="7.5" rx="1" />
          <!-- anse : fermée quand verrouillé, ouverte (décalée) sinon -->
          <path v-if="locked !== null" d="M5.2 7V5a2.8 2.8 0 0 1 5.6 0v2" />
          <path v-else d="M5.2 7V5a2.8 2.8 0 0 1 5.6 0" />
        </svg>
      </button>
    </div>
  </div>
</template>

<style scoped lang="scss">
.tape {
  --hc: var(--amber); // repère central
  --hl: var(--line); // bordures
  display: flex;
  align-items: stretch;
  gap: 6px;

  &.is-warn {
    --hc: var(--amber);
    --hl: var(--amber);

    .ruler {
      background: rgb(242 194 59 / 10%);
    }
  }

  &.is-crit {
    --hc: var(--red);
    --hl: var(--red);

    .ruler {
      background: rgb(255 91 79 / 14%);
    }
  }
}

.ruler {
  position: relative;
  flex: 1;
  min-width: 0;
  height: 30px;
  overflow: hidden;
  border-block: 1px solid var(--hl);
  transition:
    background 0.2s,
    border-color 0.2s;

  &::after {
    content: '';
    position: absolute;
    top: 0;
    bottom: 0;
    left: 50%;
    width: 2px;
    margin-left: -1px;
    background: var(--hc);
  }
}

.strip {
  position: absolute;
  top: 0;
  left: 50%;
  display: flex;
  height: 100%;
  will-change: transform;
}

.c {
  position: relative;
  flex: none;
  width: 15px;

  &::before {
    content: '';
    position: absolute;
    left: 0;
    bottom: 0;
    width: 1px;
    height: 6px;
    background: var(--cyan-dim);
  }

  &.maj::before {
    height: 11px;
    background: var(--cyan);
  }

  span {
    position: absolute;
    top: 2px;
    left: 0;
    transform: translateX(-50%);
    color: var(--muted);
    font-family: var(--font-num);
    font-size: 10px;
  }
}

// cap verrouillé : triangle rouge en haut + trait fin sur toute la hauteur
.bug {
  position: absolute;
  top: 0;
  bottom: 0;
  width: 0;
  border-left: 1px solid rgb(255 91 79 / 60%);

  &::before {
    content: '';
    position: absolute;
    top: 0;
    left: -5px;
    border-top: 7px solid var(--red);
    border-right: 5px solid transparent;
    border-left: 5px solid transparent;
  }
}

.turn {
  position: absolute;
  top: 50%;
  z-index: 1;
  padding: 0 2px;
  color: var(--hc);
  font: 700 18px/1 var(--font-num);
  letter-spacing: -2px;
  text-shadow: 0 0 6px rgb(0 0 0 / 90%);
  transform: translateY(-50%);
  animation: nudge-left 0.8s ease-in-out infinite;

  &.left {
    right: calc(50% + 3px);
  }

  &.right {
    left: calc(50% + 3px);
    animation-name: nudge-right;
  }

  .is-crit & {
    animation-duration: 0.45s; // plus pressant en rouge
  }
}

// clignote en glissant vers le côté où tourner (transform / opacity uniquement)
@keyframes nudge-left {
  0% {
    opacity: 1;
    transform: translate(0, -50%);
  }

  100% {
    opacity: 0.15;
    transform: translate(-6px, -50%);
  }
}

@keyframes nudge-right {
  0% {
    opacity: 1;
    transform: translate(0, -50%);
  }

  100% {
    opacity: 0.15;
    transform: translate(6px, -50%);
  }
}

.lock {
  display: flex;
  align-items: center;
  gap: 6px;
}

.hold {
  @include numeric;
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  line-height: 1.05;

  b {
    color: var(--red);
    font-size: 12px;
    font-weight: 600;
  }

  small {
    color: var(--muted);
    font-size: 10px;

    .is-warn & {
      color: var(--amber);
    }

    .is-crit & {
      color: var(--red);
    }
  }
}

.padlock {
  display: grid;
  place-items: center;
  width: 30px;
  height: 30px;
  padding: 0;
  border: 1px solid var(--line);
  background: transparent;
  color: var(--cyan-dim);
  cursor: pointer;

  svg {
    width: 15px;
    height: 15px;
    fill: none;
    stroke: currentColor;
    stroke-width: 1.5;

    rect {
      fill: currentColor;
      fill-opacity: 0.2;
    }
  }

  &:hover {
    color: var(--cyan);
    background: var(--off);
  }

  &.on {
    border-color: var(--red);
    color: var(--red);
  }

  &:focus-visible {
    outline: 2px solid var(--amber);
    outline-offset: 1px;
  }
}
</style>
