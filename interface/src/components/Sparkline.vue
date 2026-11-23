<script setup lang="ts">
// Mini-courbe : un point par seconde, sur les `size` dernières secondes (120 = 2 min).
// Échantillonnage à intervalle fixe pour que l'axe horizontal soit du temps, même si la valeur ne bouge pas.
// Historique de taille fixe : la mémoire ne grossit jamais.
// Sans min / max : échelle automatique sur les valeurs affichées (utile pour la mémoire).
import { computed, onMounted, onUnmounted, shallowRef } from 'vue'

const props = withDefaults(
  defineProps<{ value: number; min?: number; max?: number; size?: number; color?: string; fill?: boolean }>(),
  { size: 120, min: undefined, max: undefined, color: 'var(--red)', fill: false },
)

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
  const h = hist.value
  let lo = props.min
  let hi = props.max
  if (lo === undefined || hi === undefined) {
    const dMin = Math.min(...h)
    const dMax = Math.max(...h)
    const pad = Math.max((dMax - dMin) * 0.1, Math.abs(dMax) * 0.002, 1e-6) // marge, et pas d'échelle nulle
    lo ??= dMin - pad
    hi ??= dMax + pad
  }
  const span = hi - lo || 1
  const offset = props.size - h.length // les points arrivent par la droite
  return h.map((v, i) => `${offset + i},${(39 - Math.min(1, Math.max(0, (v - lo) / span)) * 38).toFixed(1)}`).join(' ')
})
const area = computed(() => {
  if (!props.fill || !hist.value.length) return ''
  const first = props.size - hist.value.length
  return `${first},40 ${points.value} ${props.size},40`
})
</script>

<template>
  <svg :viewBox="`0 0 ${size} 40`" preserveAspectRatio="none" aria-hidden="true">
    <line x1="0" y1="39" :x2="size" y2="39" />
    <polygon v-if="fill" :points="area" :style="{ fill: color }" class="area" />
    <polyline :points="points" :style="{ stroke: color }" />
  </svg>
</template>

<style scoped lang="scss">
svg {
  display: block;
  width: 100%;
  height: var(--spark-h, 44px);
}

line {
  stroke: var(--line);
}

.area {
  opacity: 0.15;
}

polyline {
  fill: none;
  stroke-width: 1.4;
  vector-effect: non-scaling-stroke;
}
</style>
