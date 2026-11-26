<script setup lang="ts">
// Santé, faim, soif côte à côte : utilisé à pied et dans l'écran pilote.
// Mêmes seuils pour les trois : orange sous 50 %, rouge sous 25 % (alerte plein écran à 25 %, voir alerts.ts).
import { computed } from 'vue'
import { ACT, num } from '@/telemetry'
import RingGauge from './RingGauge.vue'

// compact : version réduite pour l'écran pilote (en vol), où ces jauges sont secondaires
defineProps<{ compact?: boolean }>()

const V = `${ACT}vitals.`
const ratio = (k: string) => num(V + k + '.current') / (num(V + k + '.max', 100) || 100)
// Santé sur 100 comme dans le jeu : une blessure baisse la vie max (ex. 86), la vie pleine affiche alors 86 %.
// La part perdue (max → 100) est dessinée à part sur l'anneau.
const health = computed(() => num(V + 'health.current') / 100)
const healthCap = computed(() => Math.min(1, num(V + 'health.max', 100) / 100))
const hunger = computed(() => ratio('hunger'))
const thirst = computed(() => ratio('thirst'))
const WARN = 0.5
const CRIT = 0.25
</script>

<template>
  <div class="rings" :class="{ compact }">
    <RingGauge :value="health" :cap="healthCap" icon="health" label="Health" :warn-at="WARN" :crit-at="CRIT" />
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

// :deep : ces éléments appartiennent à RingGauge (styles scoped)
.compact {
  gap: 6px;

  :deep(.ring) {
    align-content: start; // pas d'étirement si la rangée est plus haute
    padding: 5px 4px 4px;
    gap: 2px;
  }

  :deep(svg) {
    max-width: 34px;
  }

  :deep(figcaption) {
    gap: 0;
  }

  :deep(.pct) {
    font-size: 14px;
    line-height: 1.1;
  }

  :deep(.name) {
    font-size: 8px;
    line-height: 1.2;
  }
}
</style>
