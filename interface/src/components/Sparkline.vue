<script setup lang="ts">
// Mini-courbe des dernières valeurs. Historique de taille fixe : la mémoire ne grossit jamais.
import { computed, ref, watch } from 'vue'

const props = withDefaults(defineProps<{ value: number; min: number; max: number; size?: number }>(), { size: 120 })

const hist = ref<number[]>([])
watch(
  () => props.value,
  (v) => {
    hist.value.push(v)
    if (hist.value.length > props.size) hist.value.shift()
  },
  { immediate: true },
)

const points = computed(() => {
  const span = props.max - props.min
  return hist.value
    .map((v, i) => `${i},${(39 - Math.min(1, Math.max(0, (v - props.min) / span)) * 38).toFixed(1)}`)
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
