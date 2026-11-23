<script setup lang="ts">
// Écrans affichés quand le personnage est aux commandes d'un vaisseau.
import { computed } from 'vue'
import { ACT, FLI, NO_VALUE, VEH, WPN, annunciator, bool, has, num, str } from '@/telemetry'
import MfdPanel from '@/components/MfdPanel.vue'
import SegBar from '@/components/SegBar.vue'
import VBar, { type Zone } from '@/components/VBar.vue'
import HeadingTape from '@/components/HeadingTape.vue'
import Annunciators from '@/components/Annunciators.vue'
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
// Zones relevées sur le HUD du jeu (barre pleine) : ~20 % vert, jusqu'à ~55 % jaune, rouge au-delà
const SPEED_ZONES: Zone[] = [
  { to: 0.2, color: '#57e389' },
  { to: 0.55, color: '#f2c23b' },
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

// ---- Armes : weapons.weapons.0.name, weapons.weapons.1.name… ----
// "BEHR_LaserCannon_S3_CleanAir_000000000001" → "Laser S3 CleanAir"
function prettyWeapon(raw: string): string {
  const parts = raw.replace(/_\d+$/, '').split('_').slice(1)
  return parts.map((p) => p.replace('LaserCannon', 'Laser').replace('BallisticCannon', 'Balistique')).join(' ')
}
const weapons = computed(() => {
  const list = []
  for (let i = 0; has(`${WPN}weapons.${i}.name`); i++) {
    const p = `${WPN}weapons.${i}.`
    list.push({ name: prettyWeapon(str(p + 'name')), ready: bool(p + 'ready_to_fire'), powered: bool(p + 'is_powered') })
  }
  return list
})
const countermeasures = computed(() => {
  const out = { DECOY: 0, NOISE: 0 } as Record<string, number>
  for (let i = 0; has(`${WPN}countermeasures.${i}.type`); i++) {
    out[str(`${WPN}countermeasures.${i}.type`).replace('COUNTERMEASURE_TYPE_', '')] = num(`${WPN}countermeasures.${i}.amount`)
  }
  return out
})

// ---- Systèmes ----
const POWER = [
  ['powerplants', 'Power plant'], ['engines', 'Engines'], ['weapons', 'Weapons'], ['shield_generators', 'Shields'],
  ['coolers', 'Coolers'], ['life_support', 'Life support'], ['sensors', 'Sensors'],
] as const
const IFCS = [
  ['ifcs_coupled', 'Coupled'], ['ifcs_stability', 'Stability'], ['ifcs_gravity_compensation', 'Grav. comp.'],
  ['ifcs_proximity_assist', 'Prox. assist'], ['ifcs_esp', 'ESP'], ['ifcs_speed_limiter', 'Limiter'],
] as const
// un réglage est « actif » s'il est actif, ou à défaut activé (certains n'envoient que enabled)
const ifcsOn = (k: string) => bool(`${VEH}flight.settings.${k}.active`) || bool(`${VEH}flight.settings.${k}.enabled`)

const GEAR: Record<string, string> = { DEPLOYED: 'Down', RETRACTED: 'Up', RETRACTING: 'Retracting', DEPLOYING: 'Deploying' }
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
      <!-- vitesse et boost côte à côte, comme le HUD du jeu -->
      <!-- mode de vol, en haut à gauche du module vitesse / boost -->
      <div v-if="mode" class="mode" :title="mode.guessed ? 'Deduced from the quantum drive indicator' : ''">
        <span class="badge" :class="mode.label.toLowerCase()">{{ mode.label }}</span>
      </div>
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

    <MfdPanel title="Armament" source="weapons" tab="WEAPONS">
      <div class="list">
        <div v-for="(w, i) in weapons" :key="i">
          <span>{{ w.name }}</span>
          <span class="pip" :class="w.ready ? 'on' : w.powered ? 'busy' : ''" />
        </div>
      </div>
      <div class="cms">
        <div><span class="lbl">Decoys</span><span class="num mid">{{ countermeasures.DECOY }}</span></div>
        <div><span class="lbl">Noise</span><span class="num mid">{{ countermeasures.NOISE }}</span></div>
      </div>
    </MfdPanel>

    <MfdPanel title="Systems" source="power · flight.state" tab="POWER">
      <div class="cols">
        <div class="stack">
          <span class="lbl">Gear</span>
          <span class="state" :class="{ warn: gear.endsWith('ING') }">{{ GEAR[gear] ?? '—' }}</span>
        </div>
        <div class="stack">
          <span class="lbl">Status</span>
          <span class="state">{{ bool(VEH + 'flight.state.is_landed') ? 'Landed' : 'Airborne' }}</span>
        </div>
      </div>
      <div class="list">
        <div v-for="[k, label] in POWER" :key="k">
          <span>{{ label }}</span><span class="pip" :class="{ on: bool(VEH + 'power.' + k) }" />
        </div>
      </div>
      <div class="chips">
        <span v-for="[k, label] in IFCS" :key="k" class="chip" :class="{ on: ifcsOn(k) }">{{ label }}</span>
      </div>
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

.mode {
  margin-bottom: -6px;
}

.badge {
  display: inline-block;
  padding: 2px 8px;
  border: 1px solid var(--cyan-dim);
  color: var(--cyan);
  font: 600 12px var(--font-num);
  letter-spacing: 0.14em;

  &.nav {
    border-color: var(--amber);
    color: var(--amber);
  }
}

.pair {
  display: flex;
  justify-content: space-evenly;
  align-items: flex-start;
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

.cms {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 8px;

  > div {
    display: grid;
    gap: 2px;
    padding: 8px;
    border: 1px solid var(--line);
  }
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
