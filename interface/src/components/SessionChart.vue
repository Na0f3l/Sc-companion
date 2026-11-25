<script setup lang="ts">
// Grande courbe d'une session enregistrée (panneau Sessions) : mémoire de Star Citizen (Go, remplie) et mémoire
// Windows (%, trait fin orange, échelle 0–100 à droite), pictos des événements dessous, heures en bas.
//   molette : zoom sous la souris (1 min au plus près) · glisser : se déplacer · double-clic : vue de départ
// Vue de départ : de la première à la dernière mesure (la courbe occupe toute la largeur) ; on peut dézoomer
// jusqu'aux bornes de la session (lancement du jeu → fin), où il peut ne pas y avoir de mesure.
//   survol : heure et valeurs à cet instant · focusOn(ms) : centre la vue sur un instant (liste des événements)
import { computed, ref } from 'vue'
import { buildCurve, lowerBound } from '@/chartPath'
import EventPicto, { type GameEvent } from './EventPicto.vue'

const props = defineProps<{
  t: number[] // s
  mb: (number | null)[]
  pct: (number | null)[]
  events: GameEvent[]
  start: number // ms
  end: number // ms
}>()

const W = 1000 // largeur du dessin (viewBox) ; les éléments HTML posés dessus sont placés en %
const H = 200
const MIN_SPAN = 60_000
const GAP_MS = 8000 // mesures toutes les 2 s : au-delà, le jeu était fermé

const T = computed(() => props.t.map((s) => s * 1000))
const GB = computed(() => props.mb.map((v) => (v === null ? null : v / 1024)))
const first = computed(() => Math.min(props.start, T.value[0] ?? props.start))
const last = computed(() => Math.max(props.end, T.value[T.value.length - 1] ?? props.end, first.value + MIN_SPAN))
// vue de départ : la plage des mesures (au moins MIN_SPAN)
const home = computed(() => {
  const a = T.value[0] ?? first.value
  const b = Math.max(T.value[T.value.length - 1] ?? last.value, a + MIN_SPAN)
  return { from: a, to: b }
})

// ---- Vue ----------------------------------------------------------------------------------------
const view = ref<{ from: number; to: number } | null>(null) // null = vue de départ
const from = computed(() => view.value?.from ?? home.value.from)
const to = computed(() => view.value?.to ?? home.value.to)
const pctX = (t: number) => ((t - from.value) / (to.value - from.value)) * 100

function setView(a: number, b: number): void {
  const span = Math.min(last.value - first.value, Math.max(MIN_SPAN, b - a))
  let f = a
  if (f < first.value) f = first.value
  if (f + span > last.value) f = last.value - span
  view.value = Math.abs(f - home.value.from) < 1000 && Math.abs(f + span - home.value.to) < 1000 ? null : { from: f, to: f + span }
}

/** Centre la vue sur un instant (10 min de large, ou moins si la vue est déjà plus serrée). */
function focusOn(ms: number): void {
  const span = Math.min(10 * 60_000, to.value - from.value)
  setView(ms - span / 2, ms + span / 2)
  hoverT.value = ms
}
defineExpose({ focusOn })

// ---- Courbes ------------------------------------------------------------------------------------
const ram = computed(() => buildCurve({ T: T.value, V: GB.value, from: from.value, to: to.value, width: W, height: H, buckets: 500, gapMs: GAP_MS }))
const win = computed(() => buildCurve({ T: T.value, V: props.pct, from: from.value, to: to.value, width: W, height: H, buckets: 500, gapMs: GAP_MS, min: 0, max: 100 }))

// Heures en bas : intervalle « rond » donnant au plus ~8 repères
const STEPS = [1, 2, 5, 10, 15, 30, 60, 120, 240].map((m) => m * 60_000)
const hm = (ms: number) => new Date(ms).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })
const ticks = computed(() => {
  const span = to.value - from.value
  const step = STEPS.find((s) => span / s <= 8) ?? STEPS[STEPS.length - 1]!
  const out: { x: number; label: string }[] = []
  // repères calés sur l'heure locale ronde
  const offset = new Date(from.value).getTimezoneOffset() * 60_000
  for (let t = Math.ceil((from.value - offset) / step) * step + offset; t <= to.value; t += step) out.push({ x: pctX(t), label: hm(t) })
  return out
})

const markers = computed(() =>
  props.events.filter(([t]) => t >= from.value && t <= to.value).map(([t, level, label]) => ({ t, level, label, x: pctX(t) })),
)

// ---- Survol : instant, valeurs, événement --------------------------------------------------------
const hoverT = ref<number | null>(null)
const hoverEvent = ref<GameEvent | null>(null)
const readout = computed(() => {
  if (hoverT.value === null) return null
  const i = Math.min(T.value.length - 1, lowerBound(T.value, hoverT.value))
  const near = i >= 0 && Math.abs(T.value[i]! - hoverT.value) < GAP_MS
  return {
    x: pctX(hoverT.value),
    time: new Date(hoverT.value).toLocaleTimeString('en-GB'),
    gb: near ? GB.value[i] : null,
    pct: near ? props.pct[i] : null,
  }
})

// ---- Zoom et déplacement --------------------------------------------------------------------------
const box = ref<HTMLElement>()
const timeAt = (clientX: number) => {
  const r = box.value!.getBoundingClientRect()
  return from.value + Math.min(1, Math.max(0, (clientX - r.left) / r.width)) * (to.value - from.value)
}

function onWheel(e: WheelEvent): void {
  const tc = timeAt(e.clientX)
  const k = e.deltaY > 0 ? 1.25 : 0.8
  setView(tc - (tc - from.value) * k, tc + (to.value - tc) * k)
}

let drag: { x: number; from: number; to: number; width: number; moved: boolean; id: number } | null = null
const dragging = ref(false)
function onDown(e: PointerEvent): void {
  if (e.button !== 0) return
  drag = { x: e.clientX, from: from.value, to: to.value, width: box.value!.getBoundingClientRect().width, moved: false, id: e.pointerId }
}
function onMove(e: PointerEvent): void {
  if (!drag) {
    hoverT.value = timeAt(e.clientX)
    return
  }
  const dx = e.clientX - drag.x
  if (!drag.moved) {
    if (Math.abs(dx) < 4) return
    drag.moved = dragging.value = true
    box.value!.setPointerCapture(drag.id)
    hoverT.value = null
  }
  const dt = (dx / drag.width) * (drag.to - drag.from)
  setView(drag.from - dt, drag.to - dt)
}
function onUp(): void {
  if (drag?.moved) box.value?.releasePointerCapture(drag.id)
  drag = null
  dragging.value = false
}
function onLeave(): void {
  if (!drag) hoverT.value = null
}

const fmtSpan = (ms: number) => (ms < 3_600_000 ? `${Math.round(ms / 60_000)} min` : `${(ms / 3_600_000).toFixed(1)} h`)
</script>

<template>
  <div class="chart">
    <div class="legend">
      <span class="k ram">Star Citizen RAM</span>
      <span class="k win">Windows memory %</span>
      <span class="hint">{{ view ? `${fmtSpan(to - from)} shown · double-click: reset` : 'Wheel: zoom · drag: move' }}</span>
    </div>

    <div
      ref="box"
      class="plot"
      :class="{ dragging }"
      @wheel.prevent="onWheel"
      @pointerdown="onDown"
      @pointermove="onMove"
      @pointerup="onUp"
      @pointercancel="onUp"
      @pointerleave="onLeave"
      @dblclick="view = null"
    >
      <svg class="curves" :viewBox="`0 0 ${W} ${H}`" preserveAspectRatio="none" aria-hidden="true">
        <line v-for="tk in ticks" :key="tk.label + tk.x" class="grid" :x1="tk.x * 10" :x2="tk.x * 10" y1="0" :y2="H" />
        <path class="area" :d="ram.area" />
        <path class="line" :d="ram.line" />
        <path class="bridge" :d="ram.bridge" />
        <path class="win" :d="win.line" />
        <line v-if="readout" class="cursor" :x1="readout.x * 10" :x2="readout.x * 10" y1="0" :y2="H" />
      </svg>
      <!-- échelles : Go à gauche (automatique), % à droite (0–100) -->
      <span class="scale left top">{{ ram.hi.toFixed(1) }} GB</span>
      <span class="scale left bottom">{{ Math.max(0, ram.lo).toFixed(1) }} GB</span>
      <span class="scale right top">100%</span>
      <span class="scale right bottom">0%</span>

      <div v-if="readout" class="readout" :class="{ flip: readout.x > 70 }" :style="{ left: `${readout.x}%` }">
        <b>{{ readout.time }}</b>
        <span v-if="readout.gb != null" class="ram">{{ readout.gb.toFixed(1) }} GB</span>
        <span v-if="readout.pct != null" class="win">{{ Math.round(readout.pct) }}%</span>
        <span v-if="readout.gb == null" class="off">game closed</span>
      </div>
    </div>

    <div class="marks">
      <button
        v-for="m in markers"
        :key="m.t + m.label"
        type="button"
        class="mark"
        :class="`ev-${m.level}`"
        :style="{ left: `${m.x}%` }"
        :aria-label="m.label"
        @pointerenter="hoverEvent = [m.t, m.level, m.label]"
        @pointerleave="hoverEvent = null"
        @click="focusOn(m.t)"
      >
        <EventPicto :level="m.level" />
      </button>
      <div v-if="hoverEvent" class="tip" :class="[`ev-${hoverEvent[1]}`, { flip: pctX(hoverEvent[0]) > 60 }]" :style="{ left: `${pctX(hoverEvent[0])}%` }">
        {{ hoverEvent[2] }} <span>· {{ hm(hoverEvent[0]) }}</span>
      </div>
    </div>

    <div class="axis">
      <span v-for="tk in ticks" :key="tk.label + tk.x" :style="{ left: `${tk.x}%` }">{{ tk.label }}</span>
    </div>
  </div>
</template>

<style scoped lang="scss">
.chart {
  --ram: var(--cyan);
  --win: var(--amber);
  user-select: none;
}

.legend {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 4px 16px;
  margin-bottom: 6px;

  .k {
    @include label;
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: 10px;

    &::before {
      content: '';
      width: 14px;
      height: 2px;
      background: currentColor;
    }
  }

  .ram {
    color: var(--ram);
  }

  .win {
    color: var(--win);

    &::before {
      height: 0;
      border-top: 1px dashed currentColor;
      background: none;
    }
  }

  .hint {
    margin-left: auto;
    color: var(--muted);
    font-size: 11px;
  }
}

.plot {
  position: relative;
  height: var(--plot-h, 200px);
  border: 1px solid var(--line);
  background: var(--bg);
  cursor: crosshair;
  touch-action: pan-y;

  &.dragging {
    cursor: grabbing;
  }
}

.curves {
  display: block;
  width: 100%;
  height: 100%;

  path,
  line {
    vector-effect: non-scaling-stroke;
  }

  .grid {
    stroke: var(--line);
    stroke-dasharray: 2 3;
  }

  .area {
    fill: var(--ram);
    opacity: 0.15;
  }

  .line {
    fill: none;
    stroke: var(--ram);
    stroke-width: 1.4;
  }

  // trou dans les mesures (jeu fermé…) : bords reliés en pointillés, portion déduite
  .bridge {
    fill: none;
    stroke: var(--ram);
    stroke-width: 1;
    stroke-dasharray: 3 3;
    opacity: 0.6;
  }

  .win {
    fill: none;
    stroke: var(--win);
    stroke-width: 1;
    stroke-dasharray: 4 3;
    opacity: 0.8;
  }

  .cursor {
    stroke: var(--text);
    stroke-width: 1;
    opacity: 0.5;
  }
}

.scale {
  @include numeric;
  position: absolute;
  padding: 1px 4px;
  color: var(--muted);
  font-size: 10px;
  pointer-events: none;

  &.left {
    left: 0;
  }

  &.right {
    right: 0;
    color: var(--win);
    opacity: 0.8;
  }

  &.top {
    top: 0;
  }

  &.bottom {
    bottom: 0;
  }
}

.readout {
  @include numeric;
  position: absolute;
  top: 18px;
  display: flex;
  flex-direction: column;
  gap: 1px;
  margin-left: 8px;
  padding: 3px 6px;
  border: 1px solid var(--line);
  background: var(--panel);
  font-size: 11px;
  white-space: nowrap;
  pointer-events: none;

  &.flip {
    transform: translateX(calc(-100% - 16px));
  }

  b {
    color: var(--text);
    font-weight: 600;
  }

  .ram {
    color: var(--ram);
  }

  .win {
    color: var(--win);
  }

  .off {
    color: var(--muted);
  }
}

.marks {
  position: relative;
  height: 16px;
}

.mark {
  position: absolute;
  top: 0;
  width: 14px;
  height: 100%;
  margin-left: -7px;
  padding: 0;
  border: 0;
  background: transparent;
  cursor: pointer;

  :deep(svg) {
    position: absolute;
    top: 3px;
    left: 3px;
    transition: transform 0.1s;
  }

  &:hover :deep(svg) {
    transform: scale(1.5);
  }
}

.tip {
  position: absolute;
  bottom: calc(100% + 4px);
  z-index: 2;
  max-width: 60vw;
  overflow: hidden;
  padding: 2px 6px;
  border: 1px solid var(--m);
  background: var(--panel);
  font-size: 11px;
  white-space: nowrap;
  text-overflow: ellipsis;
  transform: translateX(-8px);
  pointer-events: none;

  &.flip {
    transform: translateX(calc(-100% + 8px));
  }

  span {
    color: var(--muted);
  }
}

.axis {
  @include numeric;
  position: relative;
  height: 14px;
  color: var(--muted);
  font-size: 10px;

  span {
    position: absolute;
    transform: translateX(-50%);
  }
}
</style>
