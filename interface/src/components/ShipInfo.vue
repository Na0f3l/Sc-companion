<script setup lang="ts">
// Fiche du vaisseau : s'ouvre d'un clic sur le nom dans l'en-tête, se ferme d'un clic à côté.
// Fiche tirée de ships-info.json (wiki) et ships.json (vitesses, G de SPViewer), voir service/src/shipdata.ts.
// La fiche détaillée (~40 Ko) n'est chargée qu'à la première ouverture : rien en mémoire avant.
// Affichée hors de l'en-tête (Teleport, position absolue dans la page) : le cadre biseauté de l'en-tête
// la couperait. Absolue et non fixe : elle défile avec la page, collée au cadre du nom.
import { pageZoom } from '@/viewport'
// Loupe à droite du nom : recherche d'un autre vaisseau (suggestions à la frappe) pour consulter sa fiche.
// À la fermeture de la fiche, on revient au vaisseau piloté.
import { computed, nextTick, onBeforeUnmount, ref, shallowRef, watch } from 'vue'
import { dataUrl, searchShips, shipInfo, shipKey, shipName, shipsStamp } from '@/ships'

// Fiche détaillée (ships-info.json) : seulement ce qui ne dépend pas des composants équipés
// (boucliers, armes, quantum, signatures retirés : ils changent avec l'équipement)
interface Detail {
  role?: string
  dims?: number[]
  mass?: number
  cargo?: number
  medTier?: number
  hull?: number
  armor?: number
  armorDmg?: number[]
}

const props = defineProps<{ anchor?: HTMLElement; ship: string }>()

const open = ref(false)
const pos = ref({ top: 0, left: 0 })
type Info = { version: string | null; ships: Record<string, Detail> }
const all = shallowRef<Info | null>(null)

// élément sous lequel la fiche est ouverte : le nom du vaisseau, ou l'onglet Ship à pied (searchFrom)
const at = ref<HTMLElement>()

async function show(el = props.anchor, search = false): Promise<void> {
  if (!el || (!search && !props.ship)) return
  // positions mesurées à l'écran, ramenées à l'échelle de la page (zoom sur téléphone, voir viewport.ts)
  const z = pageZoom()
  const r = el.getBoundingClientRect()
  pos.value = { top: (r.bottom + window.scrollY) / z + 6, left: Math.max(8, Math.min(r.left / z, window.innerWidth / z - 368)) }
  at.value = el
  open.value = true
  if (search) void startSearch()
  if (!all.value) {
    try {
      all.value = (await (await fetch(dataUrl('ships-info.json'), { cache: 'no-cache' })).json()) as Info
    } catch {
      /* fiche détaillée indisponible : seules les données de vol s'affichent */
    }
  }
}
// Ouverture au clic (souris ou toucher) ; reste ouverte jusqu'à un clic à côté, un nouveau clic sur le nom
// ou Échap. (Le survol reviendra peut-être une fois la fiche triée.)
const box = ref<HTMLElement>()
function onClick(): void {
  if (open.value) open.value = false
  else void show()
}

// écouteur posé sur le nom du vaisseau (l'élément de l'en-tête passé en anchor)
watch(
  () => props.anchor,
  (el, old) => {
    old?.removeEventListener('click', onClick)
    el?.addEventListener('click', onClick)
    if (!el) open.value = false
  },
  { immediate: true },
)

// fermeture : écouteurs posés seulement quand la fiche est ouverte
function onDown(e: PointerEvent): void {
  const t = e.target as Node
  if (!box.value?.contains(t) && !at.value?.contains(t)) open.value = false
}
function onKey(e: KeyboardEvent): void {
  if (e.key !== 'Escape') return
  if (searching.value) cancelSearch() // Échap pendant la recherche : annule la recherche seulement
  else open.value = false
}

/** Ouvre la fiche directement sur la recherche, sous `el` (onglet Ship à pied). Second clic : referme. */
function searchFrom(el: HTMLElement): void {
  if (open.value && at.value === el) open.value = false
  else void show(el, true)
}
defineExpose({ searchFrom })
watch(open, (o) => {
  const fn = o ? window.addEventListener : window.removeEventListener
  fn('pointerdown', onDown as EventListener)
  fn('keydown', onKey as EventListener)
  if (!o) {
    picked.value = null // fiche refermée : retour au vaisseau piloté
    searching.value = false
  }
})

// ---- Recherche d'un autre vaisseau ----
const picked = ref<string | null>(null) // class_name choisi dans la recherche (null = vaisseau piloté)
const shown = computed(() => picked.value ?? props.ship)
const searching = ref(false)
const query = ref('')
const hit = ref(0) // suggestion surlignée (flèches haut / bas)
const input = ref<HTMLInputElement>()
const results = computed(() => searchShips(query.value))
watch(results, () => (hit.value = 0))

async function startSearch(): Promise<void> {
  query.value = ''
  searching.value = true
  await nextTick()
  input.value?.focus()
}
// recherche annulée sans fiche à montrer (ouverte à pied, rien choisi) : on referme tout
function cancelSearch(): void {
  searching.value = false
  if (!shown.value) open.value = false
}
function choose(key: string | undefined): void {
  if (!key) return
  picked.value = key
  searching.value = false
}
function onSearchKey(e: KeyboardEvent): void {
  const n = results.value.length
  if (e.key === 'ArrowDown' && n) hit.value = (hit.value + 1) % n
  else if (e.key === 'ArrowUp' && n) hit.value = (hit.value - 1 + n) % n
  else if (e.key === 'Enter') choose(results.value[hit.value]?.key)
  else return
  e.preventDefault()
}
onBeforeUnmount(() => {
  props.anchor?.removeEventListener('click', onClick)
  open.value = false
})
watch(() => props.ship, () => (open.value = false))
// données mises à jour (bouton « Update ship data ») : la fiche détaillée sera rechargée à la prochaine ouverture
watch(shipsStamp, () => (all.value = null))

const fr = new Intl.NumberFormat('en-US')
const n = (v: number | undefined, unit = '') => (v === undefined ? undefined : `${fr.format(v)}${unit}`)
const pct = (x: number) => `${Math.round(x * 100)}%`

const base = computed(() => shipInfo(shown.value))
// clé réellement utilisée : celle du modèle de base pour une variante absente des sources (DRAK_Vulture_Teach)
const key = computed(() => shipKey(shown.value))
const variant = computed(() => !!key.value && key.value !== shown.value)
const d = computed(() => (key.value ? all.value?.ships[key.value] : undefined))

type Row = [string, string | undefined]
// Sections de la fiche ; les lignes sans valeur sont masquées, les sections vides aussi
const sections = computed<{ title: string; rows: Row[] }[]>(() => {
  const b = base.value
  const x = d.value ?? {}
  const g = b?.g
  const gb = b?.gBoost
  return [
    {
      title: 'General',
      rows: [
        ['Role', x.role],
        ['Dimensions', x.dims ? `${x.dims.join(' × ')} m` : undefined],
        ['Mass', x.mass ? `${fr.format(Math.round(x.mass / 1000))} t` : undefined],
        ['Cargo', n(x.cargo, ' SCU')],
        ['Medical bed', x.medTier ? `Tier ${x.medTier}` : undefined],
      ],
    },
    {
      title: 'Flight',
      rows: [
        ['SCM speed', n(b?.scm, ' m/s')],
        ['NAV speed', n(b?.nav, ' m/s')],
        ['Boost', b?.boost ? `${fr.format(b.boost)} / ${fr.format(b.boostBack ?? 0)} m/s` : undefined],
        ['Accel. fwd / back', g ? `${g[0]} / ${g[1]} G` : undefined],
        ['Accel. up / down', g ? `${g[2]} / ${g[3]} G` : undefined],
        ['Accel. strafe', g ? `${g[4]} G` : undefined],
        ['Boosted fwd / up', gb ? `${gb[0]} / ${gb[2]} G` : undefined],
        ['Pitch / yaw / roll', b?.rot ? `${b.rot.join(' / ')} °/s` : undefined],
        ['Hydrogen fuel', n(b?.hFuel)],
        ['Quantum fuel', n(b?.qFuel)],
      ],
    },
    {
      title: 'Defense',
      rows: [
        ['Hull', n(x.hull, ' HP')],
        ['Armor', n(x.armor, ' HP')],
        ['Armor dmg taken', x.armorDmg ? `phys ${pct(x.armorDmg[0]!)} · energy ${pct(x.armorDmg[1]!)} · dist ${pct(x.armorDmg[2]!)}` : undefined],
      ],
    },
  ]
    .map((s) => ({ ...s, rows: s.rows.filter((r): r is Row => r[1] !== undefined) }))
    .filter((s) => s.rows.length)
})
</script>

<template>
  <Teleport to="body">
    <div
      v-if="open && (shown || searching)"
      ref="box"
      class="shipinfo"
      role="dialog"
      aria-label="Ship details"
      :style="{ top: `${pos.top}px`, left: `${pos.left}px` }"
    >
      <header>
        <div v-if="searching" class="search">
          <input
            ref="input"
            v-model="query"
            type="text"
            placeholder="Search a ship…"
            aria-label="Search a ship"
            autocomplete="off"
            spellcheck="false"
            @keydown="onSearchKey"
          />
          <ul v-if="results.length" role="listbox">
            <li
              v-for="(r, i) in results"
              :key="r.key"
              role="option"
              :aria-selected="i === hit"
              :class="{ hit: i === hit }"
              @pointerenter="hit = i"
              @click="choose(r.key)"
            >
              {{ r.name }}<span v-if="r.maker">{{ r.maker }}</span>
            </li>
          </ul>
          <p v-else-if="query.trim()" class="none">No ship found</p>
        </div>
        <div v-else class="title">
          <b>{{ shipName(shown) }}</b>
          <span v-if="base?.maker">{{ base.maker }}</span>
          <em v-if="picked && ship && picked !== ship">Not your current ship</em>
          <em v-else-if="variant">Special edition: base model data</em>
          <em v-else-if="!base">No data for this ship</em>
        </div>
        <button type="button" class="find" :class="{ on: searching }" :aria-label="searching ? 'Cancel search' : 'Search another ship'" :title="searching ? 'Cancel' : 'Search another ship'" @click="searching ? cancelSearch() : startSearch()">
          <svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="6.5" cy="6.5" r="4.5" /><path d="M10 10l4.5 4.5" /></svg>
        </button>
      </header>
      <p v-if="!all && base" class="wait">Loading…</p>
      <section v-for="s in sections" :key="s.title">
        <h3>{{ s.title }}</h3>
        <dl>
          <template v-for="(r, i) in s.rows" :key="i">
            <dt>{{ r[0] }}</dt>
            <dd>{{ r[1] }}</dd>
          </template>
        </dl>
      </section>
      <footer>Star Citizen Wiki · SPViewer<template v-if="all?.version"> · {{ all.version }}</template></footer>
    </div>
  </Teleport>
</template>

<style scoped lang="scss">
.shipinfo {
  position: absolute;
  z-index: 60;
  width: 360px;
  max-width: calc(100vw - 16px);
  max-height: calc(100vh - 140px);
  overflow-y: auto;
  padding: 10px 12px;
  border: 1px solid var(--cyan-dim);
  background: var(--panel);
  color: var(--text);
  font: 500 12px var(--font-ui);
  letter-spacing: 0.02em;
  box-shadow: 0 8px 24px rgb(0 0 0 / 50%);
}

header {
  display: flex;
  align-items: flex-start;
  gap: 8px;
  padding-bottom: 8px;
  border-bottom: 1px solid var(--line);
}

.title,
.search {
  flex: 1;
  min-width: 0;
}

.title {
  display: grid;
  gap: 2px;

  em {
    color: var(--amber);
    font-size: 10px;
    font-style: normal;
  }

  b {
    color: var(--cyan);
    font: 600 14px var(--font-num);
    letter-spacing: 0.08em;
    text-transform: uppercase;
  }

  span {
    color: var(--muted);
    font-size: 11px;
  }
}

.find {
  flex: none;
  display: grid;
  place-items: center;
  width: 26px;
  height: 26px;
  padding: 0;
  border: 1px solid var(--line);
  background: none;
  color: var(--cyan-dim);
  cursor: pointer;

  svg {
    width: 14px;
    height: 14px;
    fill: none;
    stroke: currentColor;
    stroke-width: 1.6;
    stroke-linecap: round;
  }

  &:hover,
  &.on {
    border-color: var(--cyan-dim);
    color: var(--cyan);
  }
}

.search {
  position: relative;

  input {
    width: 100%;
    height: 26px;
    padding: 0 8px;
    border: 1px solid var(--cyan-dim);
    background: rgb(0 0 0 / 30%);
    color: var(--cyan);
    font: 600 13px var(--font-num);
    letter-spacing: 0.06em;
    outline: none;

    &::placeholder {
      color: var(--muted);
      font-weight: 500;
      letter-spacing: 0.02em;
    }
  }

  ul {
    margin: 4px 0 0;
    padding: 0;
    list-style: none;
  }

  li {
    display: flex;
    justify-content: space-between;
    gap: 8px;
    padding: 4px 8px;
    cursor: pointer;

    span {
      color: var(--muted);
      font-size: 10px;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }

    &.hit {
      background: rgb(99 228 221 / 10%);
      color: var(--cyan);
    }
  }
}

.none {
  margin: 6px 0 0;
  color: var(--muted);
}

.wait {
  margin: 8px 0 0;
  color: var(--muted);
}

section {
  padding-top: 8px;
}

h3 {
  margin: 0 0 4px;
  @include label;
  font-size: 9px;
  color: var(--cyan-dim);
}

dl {
  display: grid;
  grid-template-columns: auto 1fr;
  gap: 2px 12px;
  margin: 0;
}

dt {
  color: var(--muted);
  white-space: nowrap;
}

dd {
  margin: 0;
  text-align: right;
  @include numeric;


}

footer {
  margin-top: 10px;
  padding-top: 6px;
  border-top: 1px solid var(--line);
  color: var(--muted);
  font-size: 10px;
}
</style>
