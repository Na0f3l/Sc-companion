<script setup lang="ts">
// Écrans affichés quand le personnage est aux commandes d'un vaisseau.
import { computed } from 'vue'
import { ACT, FLI, NO_VALUE, VEH, WPN, annunciator, bool, has, num, str } from '@/telemetry'
import MfdPanel from '@/components/MfdPanel.vue'
import SegBar from '@/components/SegBar.vue'
import VBar, { type Zone } from '@/components/VBar.vue'
import HeadingTape from '@/components/HeadingTape.vue'
import Annunciators from '@/components/Annunciators.vue'
import Diagnostics from '@/components/Diagnostics.vue'
import VitalRings from '@/components/VitalRings.vue'
import GMeter from '@/components/GMeter.vue'
import { impactLeadTime, timeToImpact } from '@/alerts'

const fr = new Intl.NumberFormat('en-US')

// ---- Instruments ----
const alt = computed(() => {
  const a = num(`${FLI}radar_altitude`, NO_VALUE * 2)
  return a > NO_VALUE ? null : a
})
const tti = computed(timeToImpact)

// Vitesse : négative en marche arrière (à confirmer en jeu : la jauge passe alors en bleu)
const speed = computed(() => num(`${FLI}speed`))
const SPEED_MAX = 1200 // m/s pour une barre pleine
// Zones relevées sur le HUD du jeu (barre pleine) : 25 % vert, 50 % jaune, 25 % rouge
const SPEED_ZONES: Zone[] = [
  { to: 0.25, color: '#57e389' },
  { to: 0.75, color: '#f2c23b' },
  { to: 1, color: '#ff5b4f' },
]
// Boost : les 25 derniers % en rouge (pas de nouveau boost possible), le reste en cyan
// Mode de vol. Le champ prévu (master_mode) n'est pas envoyé en LIVE 4.10 : on le déduit du voyant
// QDRV, allumé seulement quand le quantum est disponible, c'est-à-dire en NAV. Si le jeu envoie
// un jour master_mode, il est utilisé en priorité. Aucun sous-mode (QT, missile, minage) dans le schéma.
const MODE: Record<string, string> = { NAVIGATION: 'NAV', SCM: 'SCM', STEALTH: 'STEALTH' }
const mode = computed<{ label: string; guessed: boolean } | null>(() => {
  const real = str(`${VEH}master_mode.mode`).replace('VEHICLE_MASTER_MODE_', '')
  if (MODE[real]) return { label: MODE[real], guessed: false }
  if (!bool(`${VEH}power.powerplants`)) return null // vaisseau éteint
  return { label: annunciator('qdrv') === 'off' ? 'SCM' : 'NAV', guessed: true }
})

const BOOST_ZONES: Zone[] = [
  { to: 0.25, color: '#ff5b4f' },
  { to: 1, color: '#63e4dd' },
]
// Proche d'une planète : dans l'atmosphère (densité > 0) ou sol à portée du radar.
// Hors de là, cap / altitude / vitesse verticale n'ont pas de sens (le HUD du jeu les masque aussi).
const nearPlanet = computed(() => num(`${FLI}atmospheric_density`) > 0 || alt.value !== null)
const gMax = computed(() => num(`${FLI}g_meter.max`, 1) || 1)
const gCur = computed(() => num(`${FLI}g_meter.current`))

// ---- Leurres (le détail des armes est dans Diagnostics) ----
const countermeasures = computed(() => {
  const out = { DECOY: 0, NOISE: 0 } as Record<string, number>
  for (let i = 0; has(`${WPN}countermeasures.${i}.type`); i++) {
    out[str(`${WPN}countermeasures.${i}.type`).replace('COUNTERMEASURE_TYPE_', '')] = num(`${WPN}countermeasures.${i}.amount`)
  }
  return out
})

// ---- États du vaisseau, abrégés comme sur le HUD du jeu (affichés seulement quand actifs) ----
// seul « active » compte : « enabled » veut dire disponible (vérifié sur capture : ESP enabled mais inactif)
const ifcsOn = (k: string) => bool(`${VEH}flight.settings.${k}.active`)
// LIM (ifcs_speed_limiter) écarté : « actif » dans les mêmes trames que CPLD sur capture, donc il suit
// le mode couplé et pas l'usage réel du limiteur.
const FLAGS: [label: string, on: () => boolean, title: string][] = [
  ['CPLD', () => ifcsOn('ifcs_coupled'), 'Coupled'],
  ['ESP', () => ifcsOn('ifcs_esp'), 'Enhanced stick precision'],
  ['LIGHT', () => bool(VEH + 'lights_enabled'), 'Lights'],
  ['CRUISE', () => ifcsOn('ifcs_cruise_mode'), 'Cruise control'],
]
const flags = computed(() => FLAGS.filter(([, on]) => on()))

// Train : icône rouge sorti, orange clignotante en mouvement, rien quand il est rentré (comme en jeu)
const gear = computed(() => str(`${VEH}flight.state.gear`).replace('VEHICLE_COMPONENT_DEPLOYMENT_STATE_', ''))

// ---- Pilote ----
const ROLE: Record<string, string> = { PILOT: 'Pilot', COPILOT: 'Copilot', TURRET: 'Turret' }
const role = computed(() => {
  const r = str(`${ACT}state.crew_role`).replace('ACTOR_CREW_ROLE_', '')
  return ROLE[r] ?? (r || '—')
})
</script>

<template>
  <section class="screens">
    <MfdPanel title="Flight instruments" source="flight.instruments" tab="FLIGHT">
      <!-- comme le HUD du jeu : états du vaisseau à gauche, vitesse / boost au centre, leurres à droite -->
      <div class="top">
        <div class="hud">
          <svg
            v-if="gear && gear !== 'RETRACTED'"
            viewBox="0 0 24 24"
            class="gear"
            :class="{ moving: gear.endsWith('ING') }"
            role="img"
            :aria-label="'Landing gear ' + gear.toLowerCase()"
          >
            <title>Landing gear {{ gear.toLowerCase() }}</title>
            <path d="M8 3v6M5 3h6M15 4v10M12 11l3 3 3-3" />
            <circle cx="8" cy="14" r="4" />
            <circle cx="8" cy="14" r="1.2" />
          </svg>
          <span v-for="[label, , title] in flags" :key="label" class="flag" :title="title">{{ label }}</span>
        </div>
        <!-- mode de vol à part : centré au-dessus des deux barres (place gardée quand il est absent) -->
        <div class="speed">
          <span class="badge" :class="[mode?.label.toLowerCase(), { masked: !mode }]" :title="mode?.guessed ? 'Deduced from the quantum drive indicator' : ''">
            {{ mode?.label ?? 'SCM' }}
          </span>
          <div class="pair">
            <VBar
              :value="Math.abs(speed) / SPEED_MAX"
              :zones="SPEED_ZONES"
              :reverse="speed < 0"
              :reading="Math.round(Math.abs(speed)).toString()"
              label="m/s"
            />
            <VBar
              :value="num(FLI + 'boost.reserves')"
              :zones="BOOST_ZONES"
              :reading="`${Math.round(num(FLI + 'boost.reserves') * 100)}%`"
              label="Boost"
            >
              <span class="chip" :class="{ hot: bool(FLI + 'boost.engaged') }">AB</span>
            </VBar>
          </div>
        </div>
        <!-- leurres restants : le jeu n'envoie que le stock, pas la taille de salve choisie -->
        <div class="cm">
          <span>Decoy</span><b>{{ countermeasures.DECOY }}</b>
          <span>Noise</span><b>{{ countermeasures.NOISE }}</b>
        </div>
      </div>
      <!-- .masked : invisible mais garde sa place, donc rien ne bouge quand ça apparaît / disparaît -->
      <HeadingTape :heading="num(FLI + 'heading')" :class="{ masked: !nearPlanet }" />
      <div class="cols" :class="{ masked: !nearPlanet }">
        <div class="stack">
          <span class="lbl">Heading</span>
          <span class="num mid">{{ String(Math.round(num(FLI + 'heading')) % 360).padStart(3, '0') }}°</span>
        </div>
        <div class="stack">
          <span class="lbl">Radar alt.</span>
          <span class="num mid">
            <template v-if="alt !== null">{{ fr.format(Math.round(alt)) }}<span class="unit">m</span></template>
            <template v-else>—</template>
          </span>
        </div>
        <div class="stack">
          <span class="lbl">Vert. speed</span>
          <span class="num mid">{{ num(FLI + 'vertical_speed_indicator').toFixed(1) }}<span class="unit">m/s</span></span>
        </div>
        <!-- temps avant impact au sol, affiché seulement en descente sous 30 s -->
        <div class="stack">
          <span class="lbl">Impact</span>
          <span class="num mid" :class="{ danger: tti !== null && tti < impactLeadTime(Math.abs(speed)) }">
            <template v-if="tti !== null && tti < 30">{{ tti.toFixed(0) }}<span class="unit">s</span></template>
            <template v-else>—</template>
          </span>
        </div>
      </div>
    </MfdPanel>

    <MfdPanel title="Propulsion" source="fuel · boost · g_meter" tab="PROPULSION">
      <div class="bars">
        <div class="bar">
          <span class="num">{{ Math.round(num(FLI + 'hydrogen_fuel') * 100) }} %</span>
          <SegBar :value="num(FLI + 'hydrogen_fuel')" :segments="12" vertical />
          <span class="lbl">H-Fuel</span>
        </div>
        <!-- Q-Fuel : prévu dans le schéma mais pas encore envoyé par le jeu (LIVE 4.10) -->
        <div class="bar off">
          <span class="num">— %</span>
          <SegBar :value="0" :segments="12" vertical alert="none" />
          <span class="lbl">Q-Fuel</span>
          <span class="soon">coming soon</span>
        </div>
      </div>
      <GMeter :g="gCur" :limit="gMax" :speed="Math.abs(speed)" />
      <div class="row"><span class="lbl">G limit</span><span class="num">{{ gMax.toFixed(1) }} G</span></div>
    </MfdPanel>

    <MfdPanel title="Annunciators" source="annunciators" tab="WARNINGS">
      <Annunciators />
    </MfdPanel>

    <MfdPanel title="Diagnostics" source="power · annunciators · weapons" tab="DIAGNOSTICS">
      <Diagnostics />
    </MfdPanel>

    <MfdPanel title="Pilot" source="actor.vitals" tab="CREW">
      <VitalRings />
      <div class="cols">
        <div class="stack">
          <span class="lbl">Heart</span>
          <span class="num mid">{{ Math.round(num(ACT + 'vitals.heart_rate')) }}<span class="unit">bpm</span></span>
        </div>
        <div class="stack">
          <span class="lbl">Oxygen</span>
          <span class="num mid">{{ Math.round(num(ACT + 'vitals.oxygen.current') * 100) }}<span class="unit">%</span></span>
        </div>
      </div>
      <div class="row"><span class="lbl">Seat</span><span class="state">{{ role }}</span></div>
    </MfdPanel>

    <MfdPanel class="wide ghost" title="Hull · shields · quantum" source="vehicle.health · shields · quantum_fuel" tab="DAMAGE">
      <span class="q">NOT RECEIVED</span>
      <p>These fields exist in the schema but the game does not send them yet (LIVE 4.10).</p>
    </MfdPanel>
  </section>
</template>

<style scoped lang="scss">
// Masqué sans libérer la place (visibility, pas display) ; fondu d'opacité à l'apparition / disparition
.masked {
  opacity: 0;
  visibility: hidden;
}

.top {
  --vbar-h: 120px; // barres un peu plus courtes : moins de hauteur pour le panneau
  --mode-h: 22px; // hauteur du badge NAV / SCM au-dessus des barres
  --mode-gap: 8px;
  display: grid;
  grid-template-columns: 1fr auto 1fr; // vitesse / boost centrés, une colonne de chaque côté
  align-items: start;
  gap: 16px;
}

.speed {
  display: grid;
  justify-items: center;
  gap: var(--mode-gap);

  // badge de hauteur fixe : les colonnes latérales savent exactement où commencent les tubes
  .badge {
    height: var(--mode-h);
    line-height: calc(var(--mode-h) - 2px);
    padding-block: 0;
  }
}

// deux barres de même largeur : le milieu du bloc tombe pile entre les deux tubes
// (sinon « 100% » et la pastille AB élargissent la barre de boost et décalent le centre)
.pair {
  display: flex;
  align-items: flex-start; // pas d'étirement : valeurs et libellés des deux barres sur la même ligne
  gap: 4px;

  > * {
    width: 58px;
  }
}

// États (gauche) et leurres (droite) : même hauteur que les tubes, décalés de la hauteur du badge,
// contenu centré → centrés verticalement sur les tubes, quels que soient les textes en dessous.
.hud,
.cm {
  height: var(--vbar-h);
  margin-top: calc(var(--mode-h) + var(--mode-gap));
}

// leurres : libellé + stock, comme sur le HUD du jeu ; grille → libellés et chiffres alignés en colonnes
.cm {
  display: grid;
  grid-template-columns: auto auto;
  align-content: center;
  justify-content: start;
  gap: 6px 12px;

  span {
    color: var(--cyan);
    font: 600 12px var(--font-num);
    letter-spacing: 0.14em;
    text-transform: uppercase;
  }

  b {
    @include numeric;
    color: var(--text);
    font-size: 14px;
    text-align: right;
  }
}

// colonne d'états : badges encadrés comme sur le HUD du jeu, tous de la même largeur
.hud {
  display: flex;
  flex-direction: column;
  justify-content: center;
  align-items: flex-end; // collés à la barre de vitesse
  gap: 6px;
}

.flag {
  min-width: 62px;
  padding: 2px 6px 2px calc(6px + 0.14em); // compense l'espace ajouté après la dernière lettre
  border: 1px solid var(--cyan-dim);
  border-radius: 3px;
  color: var(--cyan);
  font: 600 12px var(--font-num);
  letter-spacing: 0.14em;
  text-align: center;
}

.gear {
  width: 22px;
  height: 22px;
  fill: none;
  stroke: var(--red);
  stroke-width: 1.8;
  stroke-linecap: round;
  stroke-linejoin: round;

  &.moving {
    stroke: var(--amber);
    animation: blink 0.5s steps(2) infinite;
  }
}

@keyframes blink {
  50% {
    opacity: 0.35;
  }
}

.badge {
  display: inline-block;
  padding: 2px 8px 2px calc(8px + 0.14em); // compense l'espace ajouté après la dernière lettre
  border: 1px solid var(--cyan-dim);
  color: var(--cyan);
  font: 600 12px var(--font-num);
  letter-spacing: 0.14em;

  &.nav {
    border-color: var(--amber);
    color: var(--amber);
  }
}

// H-Fuel / Q-Fuel alignés par le haut : la ligne « coming soon » sous Q-Fuel ne décale pas sa jauge
.bars {
  align-items: flex-start;
}

.off {
  opacity: 0.4;
}

.soon {
  @include label;
  font-size: 8px;
  letter-spacing: 0.08em;
}

.tape,
.cols {
  transition:
    opacity 0.3s,
    visibility 0.3s;
}

.danger {
  color: var(--red);
}

.ghost {
  opacity: 0.55;

  .q {
    color: var(--cyan-dim);
    font: 600 30px var(--font-num);
    letter-spacing: 0.1em;
  }

  p {
    margin: 0;
    color: var(--muted);
    font-size: 13px;
    line-height: 1.5;
  }
}
</style>
