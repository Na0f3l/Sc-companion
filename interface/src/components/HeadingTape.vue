<script setup lang="ts">
// Bande de cap. Les graduations sont générées une fois ; seul un translateX bouge
// (propriété gérée par la carte graphique, sans recalcul de la mise en page).
import { computed } from 'vue'

const props = defineProps<{ heading: number }>()

const PX_PER_DEG = 3
const CARDINAL: Record<number, string> = { 0: 'N', 90: 'E', 180: 'S', 270: 'O' }
const cells = Array.from({ length: 145 }, (_, i) => {
  const d = (((-180 + i * 5) % 360) + 360) % 360
  const major = d % 30 === 0
  return { major, label: major ? (CARDINAL[d] ?? String(d)) : '' }
})

const shift = computed(() => `translateX(${-(props.heading + 180) * PX_PER_DEG}px)`)
</script>

<template>
  <div class="tape" aria-hidden="true">
    <div class="strip" :style="{ transform: shift }">
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
