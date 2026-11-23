<script setup lang="ts">
// Bande de cap. Les graduations sont générées une fois ; seul un translateX bouge
// (propriété gérée par la carte graphique, sans recalcul de la mise en page).
//
// Lissage : une transition de 200 ms (= intervalle entre deux mises à jour du service)
// relie chaque position à la suivante, d'où un défilement continu sans rafraîchir plus souvent.
//
// Passage 359° → 0° : on suit l'angle « déroulé » (359 → 361 au lieu de 359 → 1) pour que la bande
// tourne de 2° et pas de 358° en arrière. Quand l'angle déroulé sort de la bande, on le recale
// de 360° sans transition (même graduation affichée, donc invisible).
import { computed, nextTick, ref, watch } from 'vue'

const props = defineProps<{ heading: number }>()

const PX_PER_DEG = 3
const CARDINAL: Record<number, string> = { 0: 'N', 90: 'E', 180: 'S', 270: 'O' }
// bande de -180° à 540° : on peut afficher n'importe quel angle déroulé entre -90 et 450
const cells = Array.from({ length: 145 }, (_, i) => {
  const d = (((-180 + i * 5) % 360) + 360) % 360
  const major = d % 30 === 0
  return { major, label: major ? (CARDINAL[d] ?? String(d)) : '' }
})

const shown = ref(props.heading) // angle déroulé
const animate = ref(true)

watch(
  () => props.heading,
  async (h) => {
    const delta = ((((h - shown.value) % 360) + 540) % 360) - 180 // plus court chemin, entre -180 et 180
    let next = shown.value + delta
    if (next < -90 || next > 450) {
      const wrap = next < -90 ? 360 : -360
      animate.value = false
      shown.value += wrap // recalage instantané, même image à l'écran
      await nextTick()
      requestAnimationFrame(() => {
        animate.value = true
        shown.value = next + wrap
      })
      return
    }
    shown.value = next
  },
)

const style = computed(() => ({
  transform: `translateX(${-(shown.value + 180) * PX_PER_DEG}px)`,
  transition: animate.value ? 'transform 200ms linear' : 'none',
}))
</script>

<template>
  <div class="tape" aria-hidden="true">
    <div class="strip" :style="style">
      <div v-for="(c, i) in cells" :key="i" class="c" :class="{ maj: c.major }">
        <span v-if="c.label">{{ c.label }}</span>
      </div>
    </div>
  </div>
</template>

<style scoped lang="scss">
.tape {
  position: relative;
  height: 30px;
  overflow: hidden;
  border-block: 1px solid var(--line);

  &::after {
    content: '';
    position: absolute;
    top: 0;
    bottom: 0;
    left: 50%;
    width: 2px;
    margin-left: -1px;
    background: var(--amber);
  }
}

.strip {
  position: absolute;
  top: 0;
  left: 50%;
  display: flex;
  height: 100%;
  will-change: transform;
}

.c {
  position: relative;
  flex: none;
  width: 15px;

  &::before {
    content: '';
    position: absolute;
    left: 0;
    bottom: 0;
    width: 1px;
    height: 6px;
    background: var(--cyan-dim);
  }

  &.maj::before {
    height: 11px;
    background: var(--cyan);
  }

  span {
    position: absolute;
    top: 2px;
    left: 0;
    transform: translateX(-50%);
    color: var(--muted);
    font-family: var(--font-num);
    font-size: 10px;
  }
}
</style>
