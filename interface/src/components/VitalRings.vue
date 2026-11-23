<script setup lang="ts">
// Santé, faim, soif côte à côte : utilisé à pied et dans l'écran pilote.
import { computed } from 'vue'
import { ACT, num } from '@/telemetry'
import RingGauge from './RingGauge.vue'

const V = `${ACT}vitals.`
const ratio = (k: string) => num(V + k + '.current') / (num(V + k + '.max', 100) || 100)
const health = computed(() => ratio('health'))
const hunger = computed(() => ratio('hunger'))
const thirst = computed(() => ratio('thirst'))
</script>

<template>
  <div class="rings">
    <RingGauge :value="health" icon="health" label="Santé" />
    <RingGauge :value="hunger" icon="hunger" label="Faim" />
    <RingGauge :value="thirst" icon="thirst" label="Soif" />
  </div>
</template>

<style scoped lang="scss">
.rings {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 8px;
}
</style>
