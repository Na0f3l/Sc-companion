<script setup lang="ts">
// Fiche du vaisseau : s'ouvre d'un clic sur le nom dans l'en-tête, se ferme d'un clic à côté.
// Fiche tirée de ships-info.json (wiki) et ships.json (vitesses, G de SPViewer), voir service/src/shipdata.ts.
// La fiche détaillée (~40 Ko) n'est chargée qu'à la première ouverture : rien en mémoire avant.
// Affichée hors de l'en-tête (Teleport, position absolue dans la page) : le cadre biseauté de l'en-tête
// la couperait. Absolue et non fixe : elle défile avec la page, collée au cadre du nom.
import { pageZoom } from '@/viewport'
import { computed, onBeforeUnmount, ref, shallowRef, watch } from 'vue'
import { dataUrl, shipInfo, shipsStamp } from '@/ships'

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

async function show(): Promise<void> {
  if (!props.ship || !props.anchor) return
  // positions mesurées à l'écran, ramenées à l'échelle de la page (zoom sur téléphone, voir viewport.ts)
  const z = pageZoom()
  const r = props.anchor.getBoundingClientRect()
  pos.value = { top: (r.bottom + window.scrollY) / z + 6, left: Math.max(8, Math.min(r.left / z, window.innerWidth / z - 368)) }
  open.value = true
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
  if (!box.value?.contains(t) && !props.anchor?.contains(t)) open.value = false
}
function onKey(e: KeyboardEvent): void {
  if (e.key === 'Escape') open.value = false
}
watch(open, (o) => {
  const fn = o ? window.addEventListener : window.removeEventListener
  fn('pointerdown', onDown as EventListener)
  fn('keydown', onKey as EventListener)
})
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

const base = computed(() => shipInfo(props.ship))
const d = computed(() => all.value?.ships[props.ship])

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
      v-if="open && base"
      ref="box"
      class="shipinfo"
      role="dialog"
      aria-label="Ship details"
      :style="{ top: `${pos.top}px`, left: `${pos.left}px` }"
    >
      <header>
        <b>{{ base.name }}</b>
        <span v-if="base.maker">{{ base.maker }}</span>
      </header>
      <p v-if="!all" class="wait">Loading…</p>
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
  display: grid;
  gap: 2px;
  padding-bottom: 8px;
  border-bottom: 1px solid var(--line);

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
