<script setup lang="ts">
// Écran « Diagnostics » inspiré du panneau du jeu : les composants du vaisseau par catégorie.
//
// Ce que le jeu envoie (LIVE 4.10) :
//  - l'alimentation par CATÉGORIE (vehicle.state.power.*), en tout ou rien ;
//  - le voyant d'alerte associé (PWR, THR, WPN, COOL, SHLD, RADR) : normal / mineur / majeur ;
//  - les armes une par une (nom technique, alimentée, prête à tirer).
// Ce qu'il n'envoie pas : les noms des autres composants (Thermax, Explorer…) ni leur usure / santé.
// Une catégorie éteinte n'est pas envoyée du tout : « éteint » et « absent du vaisseau » se confondent.
import { computed, reactive } from 'vue'
import { VEH, WPN, type AnnLevel, annunciator, annunciatorFlashing, bool, has, str } from '@/telemetry'

type Icon = 'power' | 'engine' | 'weapon' | 'cooler' | 'shield' | 'emitter' | 'life' | 'gravity' | 'radar'
interface Category {
  key: string // champ vehicle.state.power.<key>
  label: string
  icon: Icon
  ann?: string // voyant d'alerte correspondant
}

const CATEGORIES: Category[] = [
  { key: 'powerplants', label: 'Power Plant', icon: 'power', ann: 'pwr' },
  { key: 'coolers', label: 'Cooler', icon: 'cooler', ann: 'cool' },
  { key: 'shield_generators', label: 'Shield Generator', icon: 'shield', ann: 'shld' },
  { key: 'shield_emitters', label: 'Shield Emitter', icon: 'emitter', ann: 'shld' },
  { key: 'engines', label: 'Thrusters', icon: 'engine', ann: 'thr' },
  { key: 'weapons', label: 'Weapons', icon: 'weapon', ann: 'wpn' },
  { key: 'sensors', label: 'Radar', icon: 'radar', ann: 'radr' },
  { key: 'life_support', label: 'Life Support', icon: 'life' },
  { key: 'gravity_generators', label: 'Gravity Generator', icon: 'gravity' },
]

// Pictos SVG (grille 24×24), en currentColor
const ICONS: Record<Icon, string> = {
  power: 'M13 2 5 13.5h6L10 22l8-11.5h-6z',
  engine: 'M8 3h8l-1.5 7h-5zM7 10h10l-1 3H8zM9.5 16l2.5 5 2.5-5',
  weapon: 'M12 3v5M12 16v5M3 12h5M16 12h5M12 7a5 5 0 1 0 0 10a5 5 0 1 0 0-10',
  cooler: 'M12 2.5v19M3.8 7.2l16.4 9.6M3.8 16.8l16.4-9.6M9.5 4.5 12 7l2.5-2.5M9.5 19.5 12 17l2.5 2.5',
  shield: 'M12 3 4.5 6v5.5c0 4.8 3.2 8.2 7.5 9.5 4.3-1.3 7.5-4.7 7.5-9.5V6z',
  emitter: 'M12 7 7.5 9v3c0 3 2 5 4.5 6 2.5-1 4.5-3 4.5-6V9zM4 5.5a11 11 0 0 0 0 13M20 5.5a11 11 0 0 1 0 13',
  life: 'M12 20s-7.5-4.6-7.5-10.2A4.2 4.2 0 0 1 12 7.3a4.2 4.2 0 0 1 7.5 2.5C19.5 15.4 12 20 12 20zM6 12h3l1.5-2.5 2 5 1.5-2.5h4',
  gravity: 'M12 3v12M8 11l4 4 4-4M4 20h16',
  radar: 'M12 13a1.5 1.5 0 1 0 0 .1M8.5 16.5a5 5 0 0 1 0-7M15.5 9.5a5 5 0 0 1 0 7M5.5 19.5a9.5 9.5 0 0 1 0-13M18.5 6.5a9.5 9.5 0 0 1 0 13',
}
const POWER_ICON = 'M12 3.5v8M7.2 6.6a7 7 0 1 0 9.6 0'

// ---- Armes : "BEHR_LaserCannon_S3_948881082465" → { maker: 'Behring', type: 'Laser Cannon', size: 'S3' } ----
const MAKERS: Record<string, string> = {
  BEHR: 'Behring', KLWE: 'Klaus & Werner', AMRS: 'Amon & Reese', GATS: 'Gallenson', HRST: 'Hurston',
  MXOX: 'MaxOx', APAR: 'Apocalypse Arms', KRIG: 'Kruger', ESPR: 'Esperia', PRAR: 'Preacher', JOKR: 'Joker',
  NOVP: 'Nova Pyrotechnica', TALN: 'Talon', BANU: 'Banu', VNCL: 'Vanduul', XIAN: "Xi'an", AEGS: 'Aegis',
  ANVL: 'Anvil', RSI: 'RSI', DRAK: 'Drake', MISC: 'MISC', CRUS: 'Crusader', ORIG: 'Origin',
}
function parseWeapon(raw: string): { maker: string; type: string; size: string } {
  const parts = raw.replace(/_\d{6,}$/, '').split('_')
  const sizeIdx = parts.findIndex((p) => /^S\d+$/.test(p))
  const type = parts
    .slice(1, sizeIdx > 0 ? sizeIdx : undefined)
    .join(' ')
    .replace(/([a-z])([A-Z])/g, '$1 $2') // LaserCannon → Laser Cannon
  const maker = parts[0] ?? ''
  return { maker: MAKERS[maker] ?? maker, type: type || raw, size: sizeIdx > 0 ? (parts[sizeIdx] ?? '') : '' }
}
const weapons = computed(() => {
  const list = []
  for (let i = 0; has(`${WPN}weapons.${i}.name`); i++) {
    const p = `${WPN}weapons.${i}.`
    list.push({ ...parseWeapon(str(p + 'name')), powered: bool(p + 'is_powered'), ready: bool(p + 'ready_to_fire') })
  }
  return list
})

// ---- État d'une catégorie ----
const powered = (c: Category) => bool(`${VEH}power.${c.key}`)
const level = (c: Category): AnnLevel => (c.ann ? annunciator(c.ann) : 'off')
const flashing = (c: Category) => !!c.ann && annunciatorFlashing(c.ann)

// En-tête : nombre de catégories par niveau d'alerte, comme les compteurs du jeu
const counts = computed(() => {
  const out = { on: 0, minor: 0, major: 0 }
  for (const c of CATEGORIES) {
    if (powered(c)) out.on++
    const l = level(c)
    if (l === 'minor' || l === 'major') out[l]++
  }
  return out
})

// Ordre d'affichage : ce qui a un souci passe en tête (majeur, puis mineur), le reste garde l'ordre normal.
const RANK: Record<AnnLevel, number> = { major: 0, minor: 1, nominal: 2, off: 2 }
const sorted = computed(() => [...CATEGORIES].sort((a, b) => RANK[level(a)] - RANK[level(b)]))
// Armes : non alimentées puis pas prêtes en tête
const weaponRank = (w: { powered: boolean; ready: boolean }) => (!w.powered ? 0 : !w.ready ? 1 : 2)
const sortedWeapons = computed(() => [...weapons.value].sort((a, b) => weaponRank(a) - weaponRank(b)))

// Catégories repliées (le chevron), gardées le temps de la session
const folded = reactive<Record<string, boolean>>({})
</script>

<template>
  <div class="diag">
    <div class="head">
      <span class="lbl">Components</span>
      <span class="counts">
        <b class="on" title="Powered categories">{{ counts.on }}/{{ CATEGORIES.length }}</b>
        <b class="minor" title="Minor warnings">{{ counts.minor }}</b>
        <b class="major" title="Major warnings">{{ counts.major }}</b>
      </span>
    </div>

    <!-- liste qui défile : elle prend la hauteur laissée par les autres panneaux de la rangée -->
    <div class="scroll">
    <ul class="tree">
      <li v-for="c in sorted" :key="c.key" :data-s="level(c)" :class="{ off: !powered(c), flash: flashing(c) }">
        <button
          type="button"
          class="cat"
          :class="{ fold: c.key === 'weapons' }"
          :aria-expanded="c.key === 'weapons' ? !folded[c.key] : undefined"
          @click="c.key === 'weapons' && (folded[c.key] = !folded[c.key])"
        >
          <span v-if="c.key === 'weapons' && weapons.length" class="chev" :class="{ shut: folded[c.key] }">⌄</span>
          <span v-else class="chev none" />
          <svg viewBox="0 0 24 24" class="ico" aria-hidden="true"><path :d="ICONS[c.icon]" /></svg>
          <span class="name">{{ c.label }}</span>
          <!-- armes : nombre prêtes à tirer / total au lieu de « On » -->
          <span class="state">{{ powered(c) ? (level(c) === 'major' ? 'Fault' : level(c) === 'minor' ? 'Warn' : c.key === 'weapons' && weapons.length ? `${weapons.filter((w) => w.ready).length}/${weapons.length} ready` : 'On') : 'Off' }}</span>
          <svg viewBox="0 0 24 24" class="pwr" :class="{ on: powered(c) }" aria-hidden="true"><path :d="POWER_ICON" /></svg>
        </button>

        <!-- Armes : une ligne par arme, sous la catégorie -->
        <ul v-if="c.key === 'weapons' && !folded[c.key]" class="items">
          <li v-for="(w, i) in sortedWeapons" :key="i" :class="{ off: !w.powered }">
            <span class="name">{{ w.maker }} {{ w.type }}</span>
            <span class="size">{{ w.size }}</span>
            <span class="pip" :class="w.ready ? 'on' : w.powered ? 'busy' : ''" :title="w.ready ? 'Ready' : w.powered ? 'Not ready' : 'Unpowered'" />
          </li>
        </ul>
      </li>
    </ul>
    </div>
  </div>
</template>

<style scoped lang="scss">
.diag {
  display: grid;
  grid-template-rows: auto 1fr;
  gap: 8px;
  height: 100%;
}

// Le contenu est en absolu : il ne compte pas dans la hauteur du panneau, qui suit donc la rangée.
// min-height : hauteur minimale quand le panneau est seul sur sa ligne (téléphone).
.scroll {
  position: relative;
  min-height: 240px;

  > .tree {
    position: absolute;
    inset: 0;
    overflow-y: auto;
    overscroll-behavior: contain;
    align-content: start; // hauteur fixe : les lignes ne doivent pas s'étirer
    padding-right: 4px;
    scrollbar-width: thin;
    scrollbar-color: var(--cyan-dim) transparent;
  }
}

.head {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
}

.counts {
  @include numeric;
  display: flex;
  gap: 12px;
  font-size: 13px;
  font-weight: 600;

  .on { color: var(--cyan); }
  .minor { color: var(--amber); }
  .major { color: var(--red); }
}

.tree,
.items {
  margin: 0;
  padding: 0;
  list-style: none;
}

.tree {
  display: grid;
  gap: 3px;

  > li {
    border-left: 2px solid var(--cyan-dim);
  }
}

.cat {
  display: flex;
  align-items: center;
  gap: 8px;
  width: 100%;
  padding: 5px 6px;
  border: 0;
  border-bottom: 1px solid var(--line);
  background: rgb(99 228 221 / 4%);
  color: var(--cyan);
  font: 600 13px var(--font-ui);
  letter-spacing: 0.04em;
  text-align: left;
  cursor: default;

  &.fold { cursor: pointer; }

  &:focus-visible {
    outline: 2px solid var(--amber);
    outline-offset: -2px;
  }
}

.chev {
  width: 10px;
  font-size: 12px;
  line-height: 1;
  transition: transform 0.15s;

  &.shut { transform: rotate(-90deg); }
}

.ico,
.pwr {
  flex: none;
  width: 16px;
  height: 16px;
  fill: none;
  stroke: currentColor;
  stroke-width: 1.8;
  stroke-linecap: round;
  stroke-linejoin: round;
}

.name {
  flex: 1;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.state {
  @include numeric;
  font-size: 10px;
  letter-spacing: 0.12em;
  text-transform: uppercase;
  color: var(--muted);
}

// Bouton d'alimentation : cadre carré comme dans le jeu (affichage seul, pas de commande envoyée)
.pwr {
  box-sizing: content-box;
  padding: 2px;
  border: 1px solid var(--line);
  color: var(--cyan-dim);

  &.on {
    border-color: var(--cyan-dim);
    color: var(--cyan);
  }
}

.items li {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 4px 6px 4px 34px;
  border-bottom: 1px solid var(--line);
  font-size: 12px;
  color: var(--text);

  &.off { opacity: 0.45; }
}

.size {
  @include numeric;
  font-size: 11px;
  color: var(--muted);
}

// Couleurs selon le voyant d'alerte de la catégorie
[data-s='minor'] {
  border-left-color: var(--amber) !important;

  > .cat { color: var(--amber); }
}

[data-s='major'] {
  border-left-color: var(--red) !important;

  > .cat {
    color: var(--red);
    animation: blink 0.5s steps(2) infinite;
  }
}

.flash > .cat {
  animation: blink 0.5s steps(2) infinite;
}

.off > .cat {
  color: var(--muted);
  opacity: 0.6;
}

@keyframes blink {
  50% { opacity: 0.45; }
}
</style>
