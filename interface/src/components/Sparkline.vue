<script setup lang="ts">
// Mini-courbe : un point par seconde, sur les `size` dernières secondes (120 = 2 min).
// Échantillonnage à intervalle fixe pour que l'axe horizontal soit du temps, même si la valeur ne bouge pas.
// Historique de taille fixe : la mémoire ne grossit jamais.
import { computed, onMounted, onUnmounted, shallowRef } from 'vue'

const props = withDefaults(defineProps<{ value: number; min: number; max: number; size?: number }>(), { size: 120 })

// shallowRef + nouveau tableau à chaque point : Vue n'observe pas chaque case, juste le remplacement.
const hist = shallowRef<number[]>([])
let timer = 0
onMounted(() => {
  const sample = () => {
    const next = hist.value.length >= props.size ? hist.value.slice(1) : hist.value.slice()
    next.push(props.value)
    hist.value = next
  }
  sample()
  timer = window.setInterval(sample, 1000)
})
onUnmounted(() => clearInterval(timer))

const points = computed(() => {
  const span = props.max - props.min
  const offset = props.size - hist.value.length // les points arrivent par la droite
  return hist.value
    .map((v, i) => `${offset + i},${(39 - Math.min(1, Math.max(0, (v - props.min) / span)) * 38).toFixed(1)}`)
    .join(' ')
})
</script>

<template>
  <svg :viewBox="`0 0 ${size} 40`" preserveAspectRatio="none" aria-hidden="true">
    <line x1="0" y1="39" :x2="size" y2="39" />
    <polyline :points="points" />
  </svg>
</template>

<style scoped lang="scss">
svg {
  display: block;
  width: 100%;
  height: 44px;
}

line {
  stroke: var(--line);
}

polyline {
  fill: none;
  stroke: var(--red);
  stroke-width: 1.4;
  vector-effect: non-scaling-stroke;
}
</style>
