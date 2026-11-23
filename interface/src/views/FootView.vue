<script setup lang="ts">
// Écrans affichés quand le personnage est à pied.
import { computed } from 'vue'
import { ACT, bool, num, str } from '@/telemetry'
import MfdPanel from '@/components/MfdPanel.vue'
import SegBar from '@/components/SegBar.vue'
import Sparkline from '@/components/Sparkline.vue'

const fr = new Intl.NumberFormat('fr-FR')
const V = `${ACT}vitals.`
const hp = computed(() => num(V + 'health.current') / (num(V + 'health.max', 100) || 100))
const hunger = computed(() => num(V + 'hunger.current') / (num(V + 'hunger.max', 100) || 100))
const thirst = computed(() => num(V + 'thirst.current') / (num(V + 'thirst.max', 100) || 100))
const LOCO: Record<string, string> = { ON_FOOT: 'À pied', SEATED: 'Assis' }
const loco = computed(() => LOCO[str(`${ACT}state.locomotion`).replace('ACTOR_LOCOMOTION_STATE_', '')] ?? '—')
</script>

<template>
  <section class="screens">
    <MfdPanel class="wide" title="Biométrie" source="actor.vitals" tab="SANTÉ">
      <div class="row">
        <span class="lbl">Santé</span>
        <span><span class="num big">{{ Math.round(num(V + 'health.current')) }}</span><span class="unit">/ {{ num(V + 'health.max', 100) }}</span></span>
      </div>
      <SegBar :value="hp" :segments="20" />
      <div class="row">
        <span class="lbl">Rythme cardiaque</span>
        <span class="num mid">{{ Math.round(num(V + 'heart_rate')) }}<span class="unit">bpm</span></span>
      </div>
      <Sparkline :value="num(V + 'heart_rate')" :min="40" :max="140" />
      <div class="cols">
        <div class="stack">
          <span class="lbl">Oxygène</span>
          <span class="num mid">{{ Math.round(num(V + 'oxygen.current') * 100) }}<span class="unit">%</span></span>
        </div>
        <div class="stack">
          <span class="lbl">Temp. corps</span>
          <span class="num mid">{{ num(V + 'body_temperature.current').toFixed(1) }}<span class="unit">°C</span></span>
        </div>
      </div>
    </MfdPanel>

    <MfdPanel title="Besoins" source="hunger · thirst" tab="BESOINS">
      <div class="bars">
        <div class="bar">
          <span class="num">{{ Math.round(hunger * 100) }} %</span>
          <SegBar :value="hunger" :segments="12" vertical />
          <span class="lbl">Faim</span>
        </div>
        <div class="bar">
          <span class="num">{{ Math.round(thirst * 100) }} %</span>
          <SegBar :value="thirst" :segments="12" vertical />
          <span class="lbl">Soif</span>
        </div>
      </div>
    </MfdPanel>

    <MfdPanel title="Environnement" source="actor.environment" tab="ENVIRONNEMENT">
      <div class="list">
        <div><span class="lbl">Temp. extérieure</span><span class="num">{{ Math.round(num(ACT + 'environment.external_temperature')) }} °C</span></div>
        <div>
          <span class="lbl">Air respirable</span>
          <span class="state" :class="{ warn: !bool(ACT + 'environment.breathable_atmosphere') }">
            {{ bool(ACT + 'environment.breathable_atmosphere') ? 'Oui' : 'Non' }}
          </span>
        </div>
        <div><span class="lbl">Gravité</span><span class="num">{{ num(V + 'gravity').toFixed(2) }} g</span></div>
        <div><span class="lbl">Pression</span><span class="num">{{ num(V + 'pressure').toFixed(2) }} atm</span></div>
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
