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

const fr = new Intl.NumberFormat('en-US')
const V = `${ACT}vitals.`
const E = `${ACT}environment.`
const clamp01 = (x: number) => Math.min(1, Math.max(0, x))

// ---- Santé ----
const bodyTemp = computed(() => num(V + 'body_temperature.current'))
const heart = computed(() => num(V + 'heart_rate'))
const o2 = computed(() => num(V + 'oxygen.current') / (num(V + 'oxygen.max', 1) || 1))
// intoxication_level : absent quand il vaut 0 (le jeu n'envoie pas les zéros). Échelle supposée 0 → 100.
const intox = computed(() => clamp01(num(V + 'intoxication_level') / 100))
// Le jeu affiche une décimale (1.1 %) mais le champ est un ENTIER (int32) : jamais vu autre chose que
// absent (= 0) en LIVE 4.10, même avec 1,1 % en jeu. Affiché tel quel, sans décimale inventée.
const intoxPct = computed(() => Math.round(intox.value * 100))

// ---- Environnement ----
const gravity = computed(() => num(V + 'gravity'))
const breathable = computed(() => bool(E + 'breathable_atmosphere'))
const hPa = computed(() => num(V + 'pressure') * 1013.25) // le jeu envoie des atmosphères, son HUD affiche des hPa
const extTemp = computed(() => num(E + 'external_temperature'))
const radiation = computed(() => num(E + 'ambient_radiation_rate'))

type Tone = 'ok' | 'good' | 'warn' | 'crit'
// Température extérieure : orange au-delà de 100 °C ou en dessous de -75 °C, rouge au-delà de 150 °C ou sous -120 °C
const extTone = computed<Tone>(() => {
  const t = extTemp.value
  if (t > 150 || t < -120) return 'crit'
  if (t > 100 || t < -75) return 'warn'
  return 'ok'
})
// Température du corps : mêmes seuils que les alertes (alerts.ts)
const bodyTone = computed<Tone>(() => {
  const t = bodyTemp.value
  if (t > 40 || t < 34) return 'crit'
  if (t > 39 || t < 35) return 'warn'
  return 'ok'
})

const LOCO: Record<string, string> = { ON_FOOT: 'On foot', SEATED: 'Seated' }
const loco = computed(() => LOCO[str(`${ACT}state.locomotion`).replace('ACTOR_LOCOMOTION_STATE_', '')] ?? '—')
</script>

<template>
  <section class="screens">
    <MfdPanel class="wide" title="Health" source="actor.vitals" tab="HEALTH">
      <VitalRings />
      <div class="tiles">
        <HudTile :value="`${bodyTemp.toFixed(1)} °C`" label="Body temp" :tone="bodyTone">
          <HudIcon name="body-temp" />
        </HudTile>
        <HudTile :value="`${Math.round(heart)} bpm`" label="Heart rate" :tone="heart > 150 ? 'warn' : 'ok'">
          <HudIcon name="heart" />
        </HudTile>
        <HudTile :value="`${Math.round(o2 * 100)} %`" label="Oxygen" :tone="o2 < 0.3 ? 'crit' : 'ok'">
          <ArcMeter :value="o2" color="#3b82f6"><span class="o2">O<sub>2</sub></span></ArcMeter>
        </HudTile>
        <HudTile :value="`${intoxPct} %`" label="Drugs" :tone="intox > 0.6 ? 'crit' : intox > 0.3 ? 'warn' : 'ok'">
          <ArcMeter :value="intox" color="#f97316"><HudIcon name="pills" /></ArcMeter>
        </HudTile>
      </div>
      <Sparkline :value="heart" :min="40" :max="160" />
    </MfdPanel>

    <MfdPanel class="wide" title="Environment" source="actor.environment" tab="ENVIRONMENT">
      <div class="tiles">
        <HudTile :value="`${gravity.toFixed(2)} G`" label="Gravity">
          <HudIcon name="gravity" />
        </HudTile>
        <HudTile :value="breathable ? 'Safe' : 'Toxic'" label="Atmosphere" :tone="breathable ? 'good' : 'crit'">
          <HudIcon name="lungs" />
        </HudTile>
        <HudTile :value="`${Math.round(hPa)} hPa`" label="Pressure">
          <SpectrumDial :value="hPa / 2026"><HudIcon name="pressure" /></SpectrumDial>
        </HudTile>
        <HudTile :value="`${Math.round(extTemp)} °C`" label="Temperature" :tone="extTone">
          <!-- échelle du cadran : -150 °C (bas, bleu) → +200 °C (haut, rouge) -->
          <SpectrumDial :value="(extTemp + 150) / 350"><HudIcon name="ext-temp" /></SpectrumDial>
        </HudTile>
        <HudTile :value="`${radiation.toFixed(radiation < 10 ? 1 : 0)} R/s`" label="Radiation" :tone="radiation > 0 ? 'warn' : 'ok'">
          <SpectrumDial :value="radiation / 5"><HudIcon name="radiation" /></SpectrumDial>
        </HudTile>
      </div>
    </MfdPanel>

    <MfdPanel title="Wallet" source="actor.state.uec_balance" tab="ACCOUNT">
      <div class="stack">
        <span class="lbl">Balance</span>
        <span><span class="num big">{{ fr.format(Number(str(ACT + 'state.uec_balance', '0'))) }}</span><span class="unit">aUEC</span></span>
      </div>
      <div class="row"><span class="lbl">Movement</span><span class="state">{{ loco }}</span></div>
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
