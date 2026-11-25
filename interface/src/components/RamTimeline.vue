<script setup lang="ts">
// Courbe de la mémoire de Star Citizen + pictos des événements du jeu dessous, zoomable et déplaçable :
//   molette          zoom (de 30 s à 2 h ; en direct, le bord droit reste « maintenant », sinon zoom sous la souris)
//   glisser          se déplacer dans le temps (on quitte le direct ; revenir tout à droite le reprend)
//   double-clic      retour au direct, 5 min ; le bouton LIVE fait de même
// Historique : 2 h gardées par le service (GET /history, chargé à l'ouverture), puis un point par seconde ici.
// Défilement fluide en direct : même principe que Sparkline (une seconde de plus dessinée, glissement d'une
// seconde par battement, clock.ts). Hors direct, la vue est figée sur son instant.
import { computed, onBeforeUnmount, onMounted, ref, shallowRef, watch } from 'vue'
import { glide, tick } from '@/clock'
import { demo, str } from '@/telemetry'
import { buildCurve, lowerBound } from '@/chartPath'
import EventPicto, { type GameEvent } from './EventPicto.vue'

const props = defineProps<{ value: number | null; color: string }>()

const LIVE_SPAN = 300 // s : vue par défaut
const MIN_SPAN = 30
const MAX_SPAN = 7200 // = historique gardé
const MAX_POINTS = 7200 // un point par seconde pendant 2 h (~115 Ko au plus)
const BUCKETS = 300 // au plus 2 points dessinés par case : la courbe reste légère même à 2 h
const GAP_MS = 6000 // plus de 6 s sans mesure = jeu fermé : la courbe s'interrompt

// ---- Historique (tableaux simples, non observés ; `version` signale un changement) ----------------
const T: number[] = [] // ms
const V: number[] = [] // Go (NaN = jeu fermé)
const version = shallowRef(0)

function push(t: number, v: number): void {
  T.push(t)
  V.push(v)
  if (T.length > MAX_POINTS + 600) { T.splice(0, 600); V.splice(0, 600) } // par paquets
}

// Historique du service (mesuré en continu, une mesure / 2 s) : chargé à l'ouverture, puis rechargé quand la
// page a manqué des points. Le navigateur met en pause les minuteries d'un onglet en arrière-plan ou d'un
// téléphone écran éteint : sans ce rechargement, ces moments feraient des trous dans la courbe.
let syncing = false
async function syncHistory(): Promise<void> {
  if (demo.value || syncing) return
  syncing = true
  try {
    const h = (await (await fetch('/history', { cache: 'no-store' })).json()) as { t: number[]; mb: number[] }
    const st = h.t.map((s) => s * 1000)
    const sv = h.mb.map((mb) => mb / 1024)
    // les points d'ici plus récents que la dernière mesure du service sont gardés à la suite
    const k = lowerBound(T, (st[st.length - 1] ?? -Infinity) + 1)
    const keepT = T.slice(k)
    const keepV = V.slice(k)
    T.length = 0
    V.length = 0
    T.push(...st, ...keepT)
    V.push(...sv, ...keepV)
    version.value++
  } catch {
    /* service ancien ou injoignable : on garde les points d'ici */
  } finally {
    syncing = false
  }
}
const onVisible = () => document.visibilityState === 'visible' && void syncHistory()

onMounted(() => {
  sample()
  void syncHistory()
  document.addEventListener('visibilitychange', onVisible)
})
onBeforeUnmount(() => document.removeEventListener('visibilitychange', onVisible))

// ---- Vue : largeur (s) et bord droit (ms ; null = en direct) -------------------------------------
const span = ref(LIVE_SPAN)
const pinned = ref<number | null>(null)
const live = computed(() => pinned.value === null)
const right = computed(() => pinned.value ?? tick.value)
const start = computed(() => right.value - span.value * 1000)
const total = computed(() => (span.value + 1) * 1000) // le dessin couvre une seconde de plus (glissement)
const xOf = (t: number) => ((t - start.value) / total.value) * 1000 // en unités du dessin (0 → 1000)

const strip = ref<HTMLElement>()
function sample(): void {
  const missed = T.length > 0 && tick.value - T[T.length - 1]! > 5000 // minuteries en pause : points manqués
  push(tick.value, props.value ?? NaN)
  if (missed) void syncHistory()
  version.value++
  if (live.value) glide(strip.value, 100 / (span.value + 1))
}
watch(tick, sample)
watch(live, (on) => {
  if (!on) strip.value?.getAnimations().forEach((a) => a.cancel()) // vue figée : pas de décalage en cours
})

// ---- Courbe (chemin SVG, chartPath.ts) ----------------------------------------------------------
const curve = computed(() => {
  void version.value
  return buildCurve({
    T, V, from: start.value, to: start.value + total.value, width: 1000, height: 40,
    buckets: BUCKETS, gapMs: GAP_MS, extendTo: live.value ? start.value + total.value : undefined,
  })
})

// ---- Pictos des événements ----------------------------------------------------------------------
// point blanc = lieu ; flèche jaune ↑ / ↓ = montée / sortie de vaisseau ; losange jaune = contrat accepté, crime…
// coche verte / croix rouge = contrat terminé / échoué ; crâne vert / rouge = ennemi abattu / mort du joueur
const events = computed<GameEvent[]>(() => {
  const raw = str('log.events')
  if (!raw) return []
  try {
    return JSON.parse(raw) as GameEvent[]
  } catch {
    return []
  }
})
const markers = computed(() =>
  events.value
    .filter(([t]) => t >= start.value && t <= start.value + total.value)
    .map(([t, level, label]) => ({ t, level, label, x: xOf(t) / 10 })), // % de la bande
)

const hover = ref<number | null>(null)
const active = computed(() => {
  const e = events.value.find(([t]) => t === hover.value)
  if (!e) return null
  const x = ((e[0] - start.value) / (span.value * 1000)) * 100 // % de la zone visible
  return { level: e[1], label: e[2], x, age: (tick.value - e[0]) / 1000 }
})
let hideTimer = 0
watch(hover, (t) => {
  clearTimeout(hideTimer)
  if (t !== null) hideTimer = window.setTimeout(() => (hover.value = null), 4000) // téléphone : pas de « sortie »
})
const ago = (s: number) => (s < 60 ? `${Math.round(s)}s` : s < 3600 ? `${Math.floor(s / 60)}m` : `${Math.floor(s / 3600)}h${String(Math.floor((s % 3600) / 60)).padStart(2, '0')}`)

// ---- Zoom et déplacement --------------------------------------------------------------------------
const box = ref<HTMLElement>()
const clampSpan = (s: number) => Math.round(Math.min(MAX_SPAN, Math.max(MIN_SPAN, s)))

// bord droit demandé → direct s'il atteint « maintenant », sans aller avant le début de l'historique
function setRight(r: number): void {
  const now = Date.now()
  const oldest = (T[0] ?? now) + span.value * 200 // garder au moins 1/5 de la vue sur des données
  pinned.value = r >= now - 500 ? null : Math.max(oldest, r)
}

function onWheel(e: WheelEvent): void {
  const rect = box.value!.getBoundingClientRect()
  const frac = Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width))
  const next = clampSpan(span.value * (e.deltaY > 0 ? 1.25 : 0.8))
  if (next === span.value) return
  if (live.value) { span.value = next; return } // en direct : « maintenant » reste à droite
  const tc = start.value + frac * span.value * 1000 // instant sous la souris, gardé sous la souris
  span.value = next
  setRight(tc + (1 - frac) * next * 1000)
}

let drag: { x: number; right: number; width: number; id: number; moved: boolean } | null = null
const dragging = ref(false) // pour le curseur « main fermée »
function onDown(e: PointerEvent): void {
  if (e.button !== 0) return
  drag = { x: e.clientX, right: right.value, width: box.value!.getBoundingClientRect().width, id: e.pointerId, moved: false }
}
function onMove(e: PointerEvent): void {
  if (!drag || e.pointerId !== drag.id) return
  const dx = e.clientX - drag.x
  if (!drag.moved) {
    if (Math.abs(dx) < 4) return // petit mouvement : c'est un clic (picto), pas un déplacement
    drag.moved = true
    dragging.value = true
    box.value!.setPointerCapture(e.pointerId)
    hover.value = null
  }
  setRight(drag.right - (dx / drag.width) * span.value * 1000)
}
function onUp(e: PointerEvent): void {
  if (drag?.moved) box.value!.releasePointerCapture(e.pointerId)
  drag = null
  dragging.value = false
}
function goLive(): void {
  pinned.value = null
  span.value = LIVE_SPAN
}

const fmtSpan = (s: number) => (s < 120 ? `${s}s` : s < 7200 ? `${Math.round(s / 60)} min` : `${(s / 3600).toFixed(1)} h`)
const showChip = computed(() => !live.value || span.value !== LIVE_SPAN)
</script>

<template>
  <div
    ref="box"
    class="ramtl"
    :class="{ dragging }"
    @wheel.prevent="onWheel"
    @pointerdown="onDown"
    @pointermove="onMove"
    @pointerup="onUp"
    @pointercancel="onUp"
    @pointerleave="hover = null"
    @dblclick="goLive"
  >
    <div class="clip">
      <div ref="strip" class="strip" :style="{ width: `${(100 * (span + 1)) / span}%` }">
        <svg class="curve" viewBox="0 0 1000 40" preserveAspectRatio="none" aria-hidden="true">
          <line x1="0" y1="39" x2="1000" y2="39" />
          <path class="area" :d="curve.area" :style="{ fill: color }" />
          <path class="line" :d="curve.line" :style="{ stroke: color }" />
          <path class="bridge" :d="curve.bridge" :style="{ stroke: color }" />
        </svg>
        <div class="marks">
          <button
            v-for="m in markers"
            :key="m.t + m.label"
            type="button"
            class="mark"
            :class="`ev-${m.level}`"
            :style="{ left: `${m.x}%` }"
            :aria-label="m.label"
            @pointerenter="hover = m.t"
            @click="hover = m.t"
          >
            <EventPicto :level="m.level" />
          </button>
        </div>
      </div>
    </div>

    <!-- infobulle hors de la bande qui glisse : elle n'est pas coupée sur les bords -->
    <div v-if="active" class="tip" :class="[`ev-${active.level}`, { right: active.x > 60 }]" :style="{ left: `${active.x}%` }" role="status">
      {{ active.label }} <span>· {{ ago(active.age) }}</span>
    </div>

    <!-- vue zoomée ou déplacée : largeur affichée, retard sur le direct, retour au direct -->
    <div v-if="showChip" class="chip" @pointerdown.stop @dblclick.stop>
      <span>{{ fmtSpan(span) }}<template v-if="!live"> · {{ ago((tick - right) / 1000) }} ago</template></span>
      <button type="button" @click="goLive">LIVE ▸</button>
    </div>
  </div>
</template>

<style scoped lang="scss">
.ramtl {
  position: relative;
  display: flex;
  flex-direction: column;
  min-width: 60px;
  height: 100%;
  cursor: grab;
  touch-action: pan-y; // glisser horizontalement déplace la courbe, verticalement fait défiler la page
  user-select: none;

  &.dragging {
    cursor: grabbing;
  }
}

.clip {
  flex: 1;
  overflow: hidden;
}

.strip {
  display: grid;
  grid-template-rows: 30px 1fr;
  height: 100%;
  will-change: transform;
}

.curve {
  display: block;
  width: 100%;
  height: 30px;

  line {
    stroke: var(--line);
    vector-effect: non-scaling-stroke;
  }

  .area {
    opacity: 0.15;
  }

  .line {
    fill: none;
    stroke-width: 1.4;
    vector-effect: non-scaling-stroke;
  }

  // trou dans les mesures : bords reliés en pointillés
  .bridge {
    fill: none;
    stroke-width: 1;
    stroke-dasharray: 3 3;
    opacity: 0.6;
    vector-effect: non-scaling-stroke;
  }
}

.marks {
  position: relative;
}

// picto sous la courbe ; la zone cliquable est plus large que le dessin (doigt sur téléphone)
.mark {
  position: absolute;
  top: 0;
  width: 12px;
  height: 100%;
  margin-left: -6px;
  padding: 0;
  border: 0;
  background: transparent;
  cursor: pointer;

  :deep(svg) {
    position: absolute;
    top: 2px;
    left: 2px;
    width: 8px;
    height: 8px;
    fill: currentColor;
    transition: transform 0.1s;
  }

  &:hover :deep(svg),
  &:focus-visible :deep(svg) {
    filter: brightness(1.4);
    transform: scale(1.5);
  }

  &:focus-visible {
    outline: none;
  }
}

// infobulle au-dessus du picto, par-dessus la courbe ; ouverte vers la gauche près du bord droit
.tip {
  position: absolute;
  bottom: 18px;
  z-index: 2;
  max-width: 70vw;
  overflow: hidden;
  padding: 2px 6px;
  border: 1px solid var(--m);
  background: var(--panel);
  color: var(--m);
  font-size: 11px;
  white-space: nowrap;
  text-overflow: ellipsis;
  transform: translateX(-8px);
  pointer-events: none;

  &.right {
    transform: translateX(calc(-100% + 8px));
  }

  span {
    color: var(--muted);
  }
}

.chip {
  @include numeric;
  position: absolute;
  top: 0;
  left: 0;
  z-index: 1;
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 1px 2px 1px 5px;
  border: 1px solid var(--line);
  background: var(--panel);
  color: var(--muted);
  font-size: 10px;
  cursor: default;

  button {
    @include label;
    padding: 1px 5px;
    border: 1px solid var(--cyan-dim);
    background: transparent;
    color: var(--cyan);
    font-size: 9px;
    cursor: pointer;

    &:hover {
      background: var(--off);
    }
  }
}

</style>
