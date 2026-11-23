<script setup lang="ts">
// Santé, faim, soif côte à côte : utilisé à pied et dans l'écran pilote.
// Mêmes seuils pour les trois : orange sous 50 %, rouge sous 25 % (alerte plein écran à 25 %, voir alerts.ts).
import { computed } from 'vue'
import { ACT, num } from '@/telemetry'
import RingGauge from './RingGauge.vue'

const V = `${ACT}vitals.`
const ratio = (k: string) => num(V + k + '.current') / (num(V + k + '.max', 100) || 100)
const health = computed(() => ratio('health'))
const hunger = computed(() => ratio('hunger'))
const thirst = computed(() => ratio('thirst'))
const WARN = 0.5
const CRIT = 0.25
</script>

<template>
  <div class="rings">
    <RingGauge :value="health" icon="health" label="Health" :warn-at="WARN" :crit-at="CRIT" />
    <RingGauge :value="hunger" icon="hunger" label="Hunger" :warn-at="WARN" :crit-at="CRIT" />
    <RingGauge :value="thirst" icon="thirst" label="Thirst" :warn-at="WARN" :crit-at="CRIT" />
  </div>
</template>

<style scoped lang="scss">
.rings {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 8px;
}
</style>
