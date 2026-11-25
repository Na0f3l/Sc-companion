<script setup lang="ts">
// Mini-courbe : un point par seconde, sur les `size` dernières secondes (120 = 2 min).
// Échantillonnage à intervalle fixe pour que l'axe horizontal soit du temps, même si la valeur ne bouge pas.
// Historique de taille fixe : la mémoire ne grossit jamais.
// Sans min / max : échelle automatique sur les valeurs affichées (utile pour la mémoire).
//
// Défilement fluide : le dessin a une case de plus que la zone visible (le dernier point est prolongé jusqu'au
// bord) et glisse d'une case vers la gauche pendant la seconde (glide) ; au point suivant, tout est redessiné
// décalé d'une case et le glissement repart de zéro : aucun saut visible. Rythme commun : clock.ts.
import { computed, onMounted, ref, shallowRef, watch } from 'vue'
import { glide, tick } from '@/clock'

const props = withDefaults(
  defineProps<{ value: number; min?: number; max?: number; size?: number; color?: string; fill?: boolean }>(),
  { size: 120, min: undefined, max: undefined, color: 'var(--red)', fill: false },
)

// shallowRef + nouveau tableau à chaque point : Vue n'observe pas chaque case, juste le remplacement.
const hist = shallowRef<number[]>([])
const svg = ref<SVGSVGElement>()

function sample(): void {
  const next = hist.value.length >= props.size ? hist.value.slice(1) : hist.value.slice()
  next.push(props.value)
  hist.value = next
  glide(svg.value, 100 / props.size)
}
onMounted(sample)
watch(tick, sample)

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
  const y = (v: number) => (39 - Math.min(1, Math.max(0, (v - lo) / span)) * 38).toFixed(1)
  const offset = props.size - h.length // les points arrivent par la droite (dernier point en size − 1)
  const pts = h.map((v, i) => `${offset + i},${y(v)}`)
  if (h.length) pts.push(`${props.size},${y(h[h.length - 1]!)}`) // prolongé sur la case cachée à droite
  return pts.join(' ')
})
const area = computed(() => {
  if (!props.fill || !hist.value.length) return ''
  const first = props.size - hist.value.length
  return `${first},40 ${points.value} ${props.size},40`
})
</script>

<template>
  <div class="spark">
    <!-- une case de plus que la zone visible : size + 1 points sur size cases visibles -->
    <svg ref="svg" :viewBox="`0 0 ${size} 40`" preserveAspectRatio="none" aria-hidden="true" :style="{ width: `${(100 * size) / (size - 1)}%` }">
      <line x1="0" y1="39" :x2="size" y2="39" />
      <polygon v-if="fill" :points="area" :style="{ fill: color }" class="area" />
      <polyline :points="points" :style="{ stroke: color }" />
    </svg>
  </div>
</template>

<style scoped lang="scss">
.spark {
  overflow: hidden;
}

svg {
  display: block;
  height: var(--spark-h, 44px);
  will-change: transform;
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
