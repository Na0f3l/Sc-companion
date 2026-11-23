<script setup lang="ts">
// Écrans affichés quand le personnage est aux commandes d'un vaisseau.
import { computed } from 'vue'
import { ACT, FLI, NO_VALUE, VEH, WPN, bool, has, num, str } from '@/telemetry'
import MfdPanel from '@/components/MfdPanel.vue'
import SegBar from '@/components/SegBar.vue'
import SpeedGauge from '@/components/SpeedGauge.vue'
import HeadingTape from '@/components/HeadingTape.vue'
import Annunciators from '@/components/Annunciators.vue'
import VitalRings from '@/components/VitalRings.vue'

const fr = new Intl.NumberFormat('fr-FR')

// ---- Instruments ----
const alt = computed(() => {
  const a = num(`${FLI}radar_altitude`, NO_VALUE * 2)
  return a > NO_VALUE ? null : a
})
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
  ['powerplants', 'Centrale'], ['engines', 'Moteurs'], ['weapons', 'Armes'], ['shield_generators', 'Boucliers'],
  ['coolers', 'Refroidisseurs'], ['life_support', 'Support de vie'], ['sensors', 'Capteurs'],
] as const
const IFCS = [
  ['ifcs_coupled', 'Couplé'], ['ifcs_stability', 'Stabilité'], ['ifcs_gravity_compensation', 'Comp. gravité'],
  ['ifcs_proximity_assist', 'Aide proximité'], ['ifcs_esp', 'ESP'], ['ifcs_speed_limiter', 'Limiteur'],
] as const
// un réglage est « actif » s'il est actif, ou à défaut activé (certains n'envoient que enabled)
const ifcsOn = (k: string) => bool(`${VEH}flight.settings.${k}.active`) || bool(`${VEH}flight.settings.${k}.enabled`)

const GEAR: Record<string, string> = { DEPLOYED: 'Sorti', RETRACTED: 'Rentré', RETRACTING: 'Rentre…', DEPLOYING: 'Sort…' }
const gear = computed(() => str(`${VEH}flight.state.gear`).replace('VEHICLE_COMPONENT_DEPLOYMENT_STATE_', ''))

// ---- Pilote ----
const ROLE: Record<string, string> = { PILOT: 'Pilote', COPILOT: 'Copilote', TURRET: 'Tourelle' }
const role = computed(() => {
  const r = str(`${ACT}state.crew_role`).replace('ACTOR_CREW_ROLE_', '')
  return ROLE[r] ?? (r || '—')
})
</script>

<template>
  <section class="screens">
    <MfdPanel title="Instruments de vol" source="flight.instruments" tab="VOL">
      <SpeedGauge :value="num(FLI + 'speed')" />
      <HeadingTape :heading="num(FLI + 'heading')" />
      <div class="cols">
        <div class="stack">
          <span class="lbl">Cap</span>
          <span class="num mid">{{ String(Math.round(num(FLI + 'heading')) % 360).padStart(3, '0') }}°</span>
        </div>
        <div class="stack">
          <span class="lbl">Alt. radar</span>
          <span class="num mid">
            <template v-if="alt !== null">{{ fr.format(Math.round(alt)) }}<span class="unit">m</span></template>
            <template v-else>—</template>
          </span>
        </div>
        <div class="stack">
          <span class="lbl">Vit. vert.</span>
          <span class="num mid">{{ num(FLI + 'vertical_speed_indicator').toFixed(1) }}<span class="unit">m/s</span></span>
        </div>
      </div>
    </MfdPanel>

    <MfdPanel title="Propulsion" source="fuel · boost · g_meter" tab="PROPULSION">
      <div class="bars">
        <div class="bar">
          <span class="num">{{ Math.round(num(FLI + 'hydrogen_fuel') * 100) }} %</span>
          <SegBar :value="num(FLI + 'hydrogen_fuel')" :segments="12" vertical />
          <span class="lbl">H₂</span>
        </div>
        <div class="bar">
          <span class="num">{{ Math.round(num(FLI + 'boost.reserves') * 100) }} %</span>
          <SegBar :value="num(FLI + 'boost.reserves')" :segments="12" vertical />
          <span class="lbl">Boost</span>
        </div>
        <div class="bar">
          <span class="num">{{ gCur.toFixed(1) }}</span>
          <SegBar :value="gCur / gMax" :segments="12" vertical alert="high" />
          <span class="lbl">Charge G</span>
        </div>
      </div>
      <div class="row"><span class="lbl">Limite G</span><span class="num">{{ gMax.toFixed(1) }} G</span></div>
      <div class="row">
        <span class="lbl">Postcombustion</span>
        <span class="chip" :class="{ hot: bool(FLI + 'boost.engaged') }">{{ bool(FLI + 'boost.engaged') ? 'ACTIVE' : 'INACTIVE' }}</span>
      </div>
    </MfdPanel>

    <MfdPanel title="Voyants d'alerte" source="annunciators" tab="ALERTES">
      <Annunciators />
    </MfdPanel>

    <MfdPanel title="Armement" source="weapons" tab="ARMES">
      <div class="list">
        <div v-for="(w, i) in weapons" :key="i">
          <span>{{ w.name }}</span>
          <span class="pip" :class="w.ready ? 'on' : w.powered ? 'busy' : ''" />
        </div>
      </div>
      <div class="cms">
        <div><span class="lbl">Leurres</span><span class="num mid">{{ countermeasures.DECOY }}</span></div>
        <div><span class="lbl">Brouilleurs</span><span class="num mid">{{ countermeasures.NOISE }}</span></div>
      </div>
    </MfdPanel>

    <MfdPanel title="Systèmes" source="power · flight.state" tab="ÉNERGIE">
      <div class="cols">
        <div class="stack">
          <span class="lbl">Train</span>
          <span class="state" :class="{ warn: gear.endsWith('ING') }">{{ GEAR[gear] ?? '—' }}</span>
        </div>
        <div class="stack">
          <span class="lbl">Situation</span>
          <span class="state">{{ bool(VEH + 'flight.state.is_landed') ? 'Posé' : 'En vol' }}</span>
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

    <MfdPanel title="Pilote" source="actor.vitals" tab="ÉQUIPAGE">
      <VitalRings />
      <div class="cols">
        <div class="stack">
          <span class="lbl">Cardio</span>
          <span class="num mid">{{ Math.round(num(ACT + 'vitals.heart_rate')) }}<span class="unit">bpm</span></span>
        </div>
        <div class="stack">
          <span class="lbl">Oxygène</span>
          <span class="num mid">{{ Math.round(num(ACT + 'vitals.oxygen.current') * 100) }}<span class="unit">%</span></span>
        </div>
      </div>
      <div class="row"><span class="lbl">Poste</span><span class="state">{{ role }}</span></div>
    </MfdPanel>

    <MfdPanel class="wide ghost" title="Coque · boucliers · quantum" source="vehicle.health · shields · quantum_fuel" tab="DÉGÂTS">
      <span class="q">NON REÇU</span>
      <p>Ces champs existent dans le schéma mais le jeu ne les a pas envoyés (LIVE 4.10).</p>
    </MfdPanel>
  </section>
</template>

<style scoped lang="scss">
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
