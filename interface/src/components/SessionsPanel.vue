<script setup lang="ts">
// Panneau « Sessions » (bouton dossier de l'en-tête, même sur PC et téléphone) : sessions de jeu enregistrées par le
// service (service/src/sessions.ts), puis l'analyse d'une session : résumé, grande courbe, liste des événements.
// Les 5 dernières sessions sont gardées ; ★ en garde une indéfiniment. Rien n'est chargé tant qu'il est fermé.
import { computed, onBeforeUnmount, ref } from 'vue'
import EventPicto, { type EventLevel, type GameEvent } from './EventPicto.vue'
import SessionChart from './SessionChart.vue'
import { registerSessionsPanel } from '@/sessionsPanel'
import { tick } from '@/clock'

interface Summary {
  id: string
  saved: boolean
  live: boolean
  closingIn?: number // s : jeu fermé, la session se termine dans ce délai (sauf relance)
  start: number
  end: number
  peakMb: number
  peakPct: number
  counts: Partial<Record<EventLevel, number>>
  leaks: number
  money: { start: number; end: number; earned: number; spent: number } | null
}
interface Detail extends Summary {
  t: number[]
  mb: (number | null)[]
  pct: (number | null)[]
  events: GameEvent[]
}

const dlg = ref<HTMLDialogElement | null>(null)
const list = ref<Summary[] | null>(null)
const detail = ref<Detail | null>(null)
const error = ref('')
const confirmDelete = ref<string | null>(null)
const chart = ref<InstanceType<typeof SessionChart>>()
let refresh = 0 // session en cours ouverte : rechargée toutes les 10 s

async function api<T>(url: string, init?: RequestInit): Promise<T> {
  const res = await fetch(url, { cache: 'no-store', ...init })
  if (!res.ok) throw new Error(String(res.status))
  return (await res.json()) as T
}

// Jeu fermé : « closing in xx s », décompté ici entre deux chargements (temps écoulé depuis la réponse du
// service, pas l'heure de l'appareil : pas de souci si le téléphone n'est pas à l'heure du PC)
let listAt = 0
let detailAt = 0
const left = (closingIn: number, at: number) => Math.max(0, Math.ceil(closingIn - (tick.value - at) / 1000))

async function loadList(): Promise<void> {
  try {
    list.value = await api<Summary[]>('/sessions')
    listAt = Date.now()
    error.value = ''
  } catch {
    list.value = []
    // service arrêté, ou plus ancien que les sessions (pas redémarré depuis la mise à jour)
    error.value = "Couldn't load sessions. Restart SC Companion and try again."
  }
}

// liste ouverte : rechargée toutes les 5 s (session en cours, décompte de fermeture, fin de session)
let listTimer = 0
function watchList(on: boolean): void {
  clearInterval(listTimer)
  if (on) listTimer = window.setInterval(() => void loadList(), 5000)
}

async function open(): Promise<void> {
  detail.value = null
  confirmDelete.value = null
  dlg.value?.showModal()
  await loadList()
  watchList(true)
}
registerSessionsPanel(() => void open()) // ouvert par le menu et la bande RAM (sessionsPanel.ts)

async function show(id: string): Promise<void> {
  try {
    detail.value = await api<Detail>(`/sessions/${id}`)
    detailAt = Date.now()
    watchList(false)
  } catch {
    error.value = "Couldn't load this session."
    return
  }
  clearInterval(refresh)
  if (detail.value.live)
    refresh = window.setInterval(async () => {
      if (!detail.value?.live) return clearInterval(refresh)
      try {
        detail.value = await api<Detail>(`/sessions/${detail.value.id}`)
        detailAt = Date.now()
      } catch {
        /* réessai au prochain tour */
      }
    }, 10_000)
}

function back(): void {
  clearInterval(refresh)
  detail.value = null
  void loadList()
  watchList(true)
}

function close(): void {
  dlg.value?.close() // → stopRefresh (événement close du dialog)
}
const stopRefresh = () => {
  clearInterval(refresh)
  watchList(false)
}
onBeforeUnmount(stopRefresh)

async function toggleSave(s: Summary): Promise<void> {
  try {
    await api(`/sessions/${s.id}/${s.saved ? 'unsave' : 'save'}`, { method: 'POST' })
    s.saved = !s.saved
    if (detail.value?.id === s.id) detail.value.saved = s.saved
  } catch {
    error.value = "Couldn't change this session."
  }
  if (!detail.value) void loadList() // la rotation a pu en retirer une
}

async function remove(id: string): Promise<void> {
  if (confirmDelete.value !== id) {
    confirmDelete.value = id // premier clic : demande de confirmation
    return
  }
  confirmDelete.value = null
  try {
    await api(`/sessions/${id}`, { method: 'DELETE' })
  } catch {
    error.value = "Couldn't delete this session."
  }
  await loadList()
}

// clic sur le fond (en dehors de la boîte) : fermer
function onClick(e: MouseEvent): void {
  if (e.target === dlg.value) close()
}

// ---- Mise en forme ------------------------------------------------------------------------------
const day = (ms: number) => new Date(ms).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' })
const hm = (ms: number) => new Date(ms).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })
const hms = (ms: number) => new Date(ms).toLocaleTimeString('en-GB')
function dur(ms: number): string {
  const m = Math.max(0, Math.round(ms / 60_000))
  return m < 60 ? `${m} min` : `${Math.floor(m / 60)} h ${String(m % 60).padStart(2, '0')}`
}
const gb = (mb: number) => `${(mb / 1024).toFixed(1)} GB`

// compteurs de la liste (picto + nombre), dans cet ordre ; morts et kills : tous (PNJ + joueurs)
const COUNTS: { level: EventLevel; label: string; of: EventLevel[] }[] = [
  { level: 'death', label: 'Deaths', of: ['death', 'deathp'] },
  { level: 'kill', label: 'Kills', of: ['kill', 'killp'] },
  { level: 'success', label: 'Contracts done', of: ['success'] },
  { level: 'failure', label: 'Failures', of: ['failure'] },
  { level: 'abandon', label: 'Contracts abandoned', of: ['abandon'] },
]
const n = (s: Summary, ...levels: EventLevel[]) => levels.reduce((sum, l) => sum + (s.counts[l] ?? 0), 0)
const countsOf = (s: Summary) => COUNTS.map((c) => ({ ...c, n: n(s, ...c.of) })).filter((c) => c.n > 0)

// K/D : kills / morts (sans mort, le nombre de kills, comme l'outil PowerShell) ; tous, ou contre des joueurs
function kd(k: number, d: number): { ratio: string; detail: string } {
  return { ratio: k + d ? (k / Math.max(1, d)).toFixed(2) : '—', detail: `${k} kill${k === 1 ? '' : 's'} · ${d} death${d === 1 ? '' : 's'}` }
}
const kdAll = computed(() => (detail.value ? kd(n(detail.value, 'kill', 'killp'), n(detail.value, 'death', 'deathp')) : null))
const kdPlayers = computed(() => (detail.value ? kd(n(detail.value, 'killp'), n(detail.value, 'deathp')) : null))

// argent : variation du solde sur la session, avec le total gagné et le total dépensé
const uec = (v: number) => Math.round(v).toLocaleString('en-US')
const money = computed(() => {
  const m = detail.value?.money
  if (!m) return null
  const net = m.end - m.start
  return { net: `${net > 0 ? '+' : net < 0 ? '−' : ''}${uec(Math.abs(net))}`, tone: net > 0 ? 'ev-success' : net < 0 ? 'ev-failure' : '', earned: uec(m.earned), spent: uec(m.spent) }
})

const contractsFailed = computed(() => (detail.value ? (detail.value.counts.failure ?? 0) - detail.value.leaks : 0))
const events = computed(() => (detail.value ? [...detail.value.events].sort((a, b) => a[0] - b[0]) : []))
</script>

<template>
  <!-- la boîte (dialog) ne défile pas : elle porte la croix, hors du cadre et toujours visible ;
       le contenu défile dans le cadre biseauté -->
  <dialog ref="dlg" class="box" aria-labelledby="ss-title" @click="onClick" @close="stopRefresh">
    <button type="button" class="x" aria-label="Close" title="Close" @click="close">✕</button>
    <div class="frame">
    <header>
      <button v-if="detail" type="button" class="back" @click="back">‹ Sessions</button>
      <h2 v-else id="ss-title">Sessions</h2>
    </header>

    <p v-if="error" class="err">{{ error }}</p>

    <!-- ===== Liste ===== -->
    <template v-if="!detail">
      <p class="lead">Every game session is recorded while SC Companion is running. The last 5 are kept; ★ keeps one forever.</p>
      <p v-if="list && !list.length && !error" class="empty">No session yet. Launch the game with SC Companion running.</p>
      <ul v-if="list?.length" class="list">
        <li v-for="s in list" :key="s.id" :class="{ live: s.live }">
          <button type="button" class="open" @click="show(s.id)">
            <span class="when">
              <b>{{ day(s.start) }}</b> · {{ hm(s.start) }}
              <span v-if="s.live" class="rec">● REC</span>
              <span v-if="s.live && s.closingIn !== undefined" class="closing">closing in {{ left(s.closingIn, listAt) }} s</span>
            </span>
            <span class="stats">
              <span>{{ dur(s.end - s.start) }}</span>
              <span>peak {{ gb(s.peakMb) }}</span>
              <span v-for="c in countsOf(s)" :key="c.level" class="count" :class="`ev-${c.level}`" :title="c.label">
                <EventPicto :level="c.level" />{{ c.n }}
              </span>
            </span>
          </button>
          <button type="button" class="icon star" :class="{ on: s.saved }" :title="s.saved ? 'Kept forever · click to release' : 'Keep forever'" :aria-pressed="s.saved" @click="toggleSave(s)">★</button>
          <button
            type="button"
            class="icon del"
            :class="{ confirm: confirmDelete === s.id }"
            :disabled="s.live"
            :title="s.live ? 'Session in progress' : 'Delete'"
            @click="remove(s.id)"
          >
            {{ confirmDelete === s.id ? 'Delete?' : '✕' }}
          </button>
        </li>
      </ul>
    </template>

    <!-- ===== Analyse d'une session ===== -->
    <template v-else>
      <div class="title">
        <h2 id="ss-title">{{ day(detail.start) }} · {{ hm(detail.start) }} – {{ detail.live ? 'now' : hm(detail.end) }}</h2>
        <span v-if="detail.live" class="rec">● REC</span>
        <span v-if="detail.live && detail.closingIn !== undefined" class="closing">closing in {{ left(detail.closingIn, detailAt) }} s</span>
        <button type="button" class="icon star" :class="{ on: detail.saved }" :aria-pressed="detail.saved" @click="toggleSave(detail)">
          ★ <span>{{ detail.saved ? 'Kept forever' : 'Keep forever' }}</span>
        </button>
      </div>

      <dl class="tiles">
        <div><dt>Duration</dt><dd>{{ dur(detail.end - detail.start) }}</dd></div>
        <div><dt>Peak game RAM</dt><dd>{{ gb(detail.peakMb) }}</dd></div>
        <div><dt>Peak Windows memory</dt><dd>{{ Math.round(detail.peakPct) }}%</dd></div>
        <div>
          <dt>K/D · all</dt>
          <dd>{{ kdAll!.ratio }}<small>{{ kdAll!.detail }}</small></dd>
        </div>
        <div title="Players you shot down · times a player killed you">
          <dt>K/D · players</dt>
          <dd>{{ kdPlayers!.ratio }}<small>{{ kdPlayers!.detail }}</small></dd>
        </div>
        <div title="Change of your aUEC balance during the session">
          <dt>Money</dt>
          <dd v-if="money" :class="money.tone">{{ money.net }}<small>+{{ money.earned }} · −{{ money.spent }} aUEC</small></dd>
          <dd v-else>—<small>balance not received</small></dd>
        </div>
        <div><dt>Contracts</dt><dd><span class="ev-success">{{ detail.counts.success ?? 0 }} ✔</span> <span class="ev-failure">{{ contractsFailed }} ✕</span> <span v-if="detail.counts.abandon" class="ev-abandon">{{ detail.counts.abandon }} ✕</span></dd></div>
        <div><dt>RAM leaks</dt><dd :class="detail.leaks ? 'ev-failure' : ''">{{ detail.leaks }}</dd></div>
      </dl>

      <!-- la courbe reste visible quand on fait défiler les événements (30 % de l'écran au plus) -->
      <div class="sticky">
        <SessionChart ref="chart" :t="detail.t" :mb="detail.mb" :pct="detail.pct" :events="detail.events" :start="detail.start" :end="detail.end" />
      </div>

      <h3>Events <small>click one to see it on the chart</small></h3>
      <p v-if="!events.length" class="empty">No event recorded in this session.</p>
      <ol v-else class="events">
        <li v-for="e in events" :key="e[0] + e[2]">
          <button type="button" @click="chart?.focusOn(e[0])">
            <time>{{ hms(e[0]) }}</time>
            <span class="pic" :class="`ev-${e[1]}`"><EventPicto :level="e[1]" /></span>
            <span class="lbl">{{ e[2] }}</span>
          </button>
        </li>
      </ol>
    </template>
    </div>
  </dialog>
</template>

<style scoped lang="scss">
button:focus-visible {
  outline: 2px solid var(--amber);
  outline-offset: 1px;
}

// Boîte transparente, plus petite que l'écran (marge tout autour) : la croix est posée à l'extérieur du cadre
.box {
  width: min(1060px, calc(100vw - 120px));
  height: calc(100vh - 96px);
  max-width: none;
  max-height: none;
  padding: 0;
  border: 0;
  background: none;
  color: var(--text);
  overflow: visible;

  &::backdrop {
    background: rgb(0 0 0 / 70%);
  }
}

// cadre biseauté qui défile
.frame {
  height: 100%;
  padding: 12px 16px 16px;
  overflow: auto;
  border: 1px solid var(--cyan-dim);
  @include bevel-edges-bg(10px, var(--cyan-dim), var(--panel));
  @include bevel(10px);
}

// fermer : à droite du coin haut du cadre, hors de la zone qui défile
.x {
  position: absolute;
  top: 0;
  left: calc(100% + 10px);
  width: 34px;
  height: 34px;
  padding: 0;
  border: 1px solid var(--cyan-dim);
  background: var(--panel);
  color: var(--cyan);
  font-size: 15px;
  cursor: pointer;

  &:hover {
    border-color: var(--cyan);
    background: var(--off);
  }
}

header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 8px;
}

h2 {
  margin: 0;
  @include label;
  color: var(--cyan);
  font-size: 12px;
}

.back {
  padding: 2px 6px;
  border: 0;
  background: none;
  color: var(--muted);
  font: 600 12px var(--font-ui);
  letter-spacing: 0.08em;
  text-transform: uppercase;
  cursor: pointer;

  &:hover {
    color: var(--cyan);
  }
}

.back {
  padding-left: 0;
  color: var(--cyan);
}

p {
  margin: 0 0 10px;
  font: 500 12px/1.45 var(--font-ui);
  letter-spacing: 0.02em;
}

.lead,
.empty {
  color: var(--muted);
}

.err {
  color: var(--amber);
}

// jeu fermé : la session se termine si le jeu n'est pas relancé avant la fin du décompte
.closing {
  @include numeric;
  margin-left: 8px;
  color: var(--amber);
  font-size: 11px;
}

.rec {
  @include label;
  margin-left: 8px;
  color: var(--red);
  font-size: 10px;
  animation: rec 1.6s ease-in-out infinite;
}

@keyframes rec {
  50% {
    opacity: 0.35;
  }
}

// ---- Liste ----
.list {
  margin: 0;
  padding: 0;
  list-style: none;

  li {
    display: flex;
    align-items: stretch;
    gap: 6px;
    border-bottom: 1px solid var(--line);

    &.live .open {
      border-left: 2px solid var(--red);
    }
  }
}

.open {
  display: flex;
  flex: 1;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 4px 16px;
  min-width: 0;
  padding: 9px 8px;
  border: 0;
  border-left: 2px solid transparent;
  background: none;
  color: var(--text);
  text-align: left;
  cursor: pointer;

  &:hover {
    background: var(--off);
  }
}

.when {
  font-size: 13px;

  b {
    color: var(--cyan);
    font-weight: 600;
  }
}

.stats {
  @include numeric;
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 4px 14px;
  color: var(--muted);
  font-size: 12px;
}

.count {
  display: inline-flex;
  align-items: center;
  gap: 4px;
}

.icon {
  min-width: 34px;
  padding: 0 8px;
  border: 0;
  background: none;
  color: var(--muted);
  font-size: 14px;
  cursor: pointer;

  &:hover:not(:disabled) {
    color: var(--cyan);
    background: var(--off);
  }

  &:disabled {
    opacity: 0.3;
    cursor: default;
  }
}

.star.on {
  color: var(--amber);
}

.del.confirm {
  @include label;
  color: var(--red);
  font-size: 10px;
}

// ---- Analyse ----
.title {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 6px 10px;
  margin-bottom: 10px;

  h2 {
    font-size: 13px;
    color: var(--text);
  }

  .star {
    margin-left: auto;
    padding: 4px 10px;
    border: 1px solid var(--line);
    font-size: 12px;

    span {
      @include label;
      font-size: 10px;
    }
  }
}

.tiles {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(130px, 1fr));
  gap: 6px;
  margin: 0 0 14px;

  div {
    padding: 6px 8px;
    border: 1px solid var(--line);
    background: var(--bg);
  }

  dt {
    @include label;
    font-size: 9px;
  }

  dd {
    @include numeric;
    margin: 2px 0 0;
    color: var(--text);
    font-size: 17px;
    font-weight: 600;

    &[class*='ev-'] {
      color: var(--m);
    }

    small {
      display: block;
      color: var(--muted);
      font-size: 10px;
      font-weight: 400;
    }
  }
}

// courbe collée en haut du panneau pendant le défilement ; hauteur de la zone de tracé ramenée pour que
// l'ensemble (légende, tracé, pictos, heures) ne dépasse jamais 30 % de l'écran
.sticky {
  --plot-h: clamp(60px, calc(30vh - 78px), 200px);
  position: sticky;
  top: -12px; // compense la marge haute du panneau
  z-index: 3;
  margin: 0 -16px;
  padding: 8px 16px 4px;
  border-bottom: 1px solid var(--line);
  background: var(--panel);
}

h3 {
  @include label;
  margin: 14px 0 6px;
  color: var(--cyan);
  font-size: 11px;

  small {
    margin-left: 8px;
    color: var(--muted);
    font-size: 10px;
    letter-spacing: 0.04em;
    text-transform: none;
  }
}

.events {
  margin: 0;
  padding: 0;
  list-style: none;

  button {
    display: flex;
    align-items: center;
    gap: 10px;
    width: 100%;
    padding: 4px 6px;
    border: 0;
    border-bottom: 1px solid var(--off);
    background: none;
    color: var(--text);
    font-size: 12px;
    text-align: left;
    cursor: pointer;

    &:hover {
      background: var(--off);
    }
  }

  time {
    @include numeric;
    flex: none;
    color: var(--muted);
  }

  .pic {
    flex: none;
  }

  .lbl {
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
}
</style>
