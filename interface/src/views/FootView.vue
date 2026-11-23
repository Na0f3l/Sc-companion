<script setup lang="ts">
// Écrans affichés quand le personnage est à pied. Pictos et jauges inspirés de l'écran Santé / Environnement du jeu.
import { computed } from 'vue'
import { ACT, bool, num, str } from '@/telemetry'
import MfdPanel from '@/components/MfdPanel.vue'
import Sparkline from '@/components/Sparkline.vue'
import VitalRings from '@/components/VitalRings.vue'
import HudTile from '@/components/HudTile.vue'
import HudIcon from '@/components/HudIcon.vue'
import ArcMeter from '@/components/ArcMeter.vue'
import SpectrumDial from '@/components/SpectrumDial.vue'

const fr = new Intl.NumberFormat('fr-FR')
const V = `${ACT}vitals.`
const E = `${ACT}environment.`
const clamp01 = (x: number) => Math.min(1, Math.max(0, x))

// ---- Santé ----
const bodyTemp = computed(() => num(V + 'body_temperature.current'))
const heart = computed(() => num(V + 'heart_rate'))
const o2 = computed(() => num(V + 'oxygen.current') / (num(V + 'oxygen.max', 1) || 1))
// intoxication_level : absent quand il vaut 0 (le jeu n'envoie pas les zéros). Échelle supposée 0 → 100.
const intox = computed(() => clamp01(num(V + 'intoxication_level') / 100))

// ---- Environnement ----
const gravity = computed(() => num(V + 'gravity'))
const breathable = computed(() => bool(E + 'breathable_atmosphere'))
const hPa = computed(() => num(V + 'pressure') * 1013.25) // le jeu envoie des atmosphères, son HUD affiche des hPa
const extTemp = computed(() => num(E + 'external_temperature'))
const radiation = computed(() => num(E + 'ambient_radiation_rate'))

const LOCO: Record<string, string> = { ON_FOOT: 'À pied', SEATED: 'Assis' }
const loco = computed(() => LOCO[str(`${ACT}state.locomotion`).replace('ACTOR_LOCOMOTION_STATE_', '')] ?? '—')
</script>

<template>
  <section class="screens">
    <MfdPanel class="wide" title="Santé" source="actor.vitals" tab="SANTÉ">
      <VitalRings />
      <div class="tiles">
        <HudTile :value="`${Math.round(bodyTemp)} °C`" label="Temp. corps" :tone="bodyTemp > 38.5 || bodyTemp < 35 ? 'warn' : 'ok'">
          <HudIcon name="body-temp" />
        </HudTile>
        <HudTile :value="`${Math.round(heart)} bpm`" label="Cardio" :tone="heart > 150 ? 'warn' : 'ok'">
          <HudIcon name="heart" />
        </HudTile>
        <HudTile :value="`${Math.round(o2 * 100)} %`" label="Oxygène" :tone="o2 < 0.3 ? 'crit' : 'ok'">
          <ArcMeter :value="o2" color="#3b82f6"><span class="o2">O<sub>2</sub></span></ArcMeter>
        </HudTile>
        <HudTile :value="`${Math.round(intox * 100)} %`" label="Drogues" :tone="intox > 0.6 ? 'crit' : intox > 0.3 ? 'warn' : 'ok'">
          <ArcMeter :value="intox" color="#f97316"><HudIcon name="pills" /></ArcMeter>
        </HudTile>
      </div>
      <Sparkline :value="heart" :min="40" :max="160" />
    </MfdPanel>

    <MfdPanel class="wide" title="Environnement" source="actor.environment" tab="ENVIRONNEMENT">
      <div class="tiles">
        <HudTile :value="`${gravity.toFixed(2)} G`" label="Gravité">
          <HudIcon name="gravity" />
        </HudTile>
        <HudTile :value="breathable ? 'Sain' : 'Toxique'" label="Atmosphère" :tone="breathable ? 'good' : 'crit'">
          <HudIcon name="lungs" />
        </HudTile>
        <HudTile :value="`${Math.round(hPa)} hPa`" label="Pression">
          <SpectrumDial :value="hPa / 2026"><HudIcon name="pressure" /></SpectrumDial>
        </HudTile>
        <HudTile :value="`${Math.round(extTemp)} °C`" label="Température">
          <SpectrumDial :value="(extTemp + 60) / 160"><HudIcon name="ext-temp" /></SpectrumDial>
        </HudTile>
        <HudTile :value="`${radiation.toFixed(radiation < 10 ? 1 : 0)} R/s`" label="Radiations" :tone="radiation > 0 ? 'warn' : 'ok'">
          <SpectrumDial :value="radiation / 5"><HudIcon name="radiation" /></SpectrumDial>
        </HudTile>
      </div>
    </MfdPanel>

    <MfdPanel title="Portefeuille" source="actor.state.uec_balance" tab="COMPTE">
      <div class="stack">
        <span class="lbl">Solde</span>
        <span><span class="num big">{{ fr.format(Number(str(ACT + 'state.uec_balance', '0'))) }}</span><span class="unit">aUEC</span></span>
      </div>
      <div class="row"><span class="lbl">Déplacement</span><span class="state">{{ loco }}</span></div>
    </MfdPanel>
  </section>
</template>

<style scoped lang="scss">
.tiles {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(68px, 1fr));
  gap: 8px;
}

.o2 {
  font: 700 15px var(--font-num);

  sub {
    font-size: 9px;
  }
}
</style>
