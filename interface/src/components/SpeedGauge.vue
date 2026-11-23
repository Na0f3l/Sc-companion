<script setup lang="ts">
// Jauge de vitesse en arc de 240°. Le tracé (arc, graduations) est calculé une seule fois ;
// à chaque mise à jour, seul l'attribut stroke-dasharray de l'arc coloré change.
import { computed } from 'vue'

const props = withDefaults(defineProps<{ value: number; max?: number; unit?: string }>(), { max: 1000, unit: 'm/s' })

const polar = (deg: number, r: number): [number, number] => {
  const a = ((deg - 90) * Math.PI) / 180
  return [100 + r * Math.cos(a), 100 + r * Math.sin(a)]
}
const [x0, y0] = polar(-120, 72)
const [x1, y1] = polar(120, 72)
const arc = `M${x0} ${y0} A72 72 0 1 1 ${x1} ${y1}`

const ticks = Array.from({ length: 11 }, (_, i) => {
  const deg = -120 + i * 24
  const major = i % 5 === 0
  const [ax, ay] = polar(deg, 84)
  const [bx, by] = polar(deg, major ? 93 : 89)
  const [lx, ly] = polar(deg, 62)
  return { ax, ay, bx, by, lx, ly: ly + 3, major, label: major ? String((props.max / 10) * i) : '' }
})

const dash = computed(() => `${Math.min(1, Math.max(0, props.value / props.max)) * 100} 100`)
</script>

<template>
  <div class="gauge">
    <svg viewBox="0 0 200 150" aria-hidden="true">
      <g v-for="(t, i) in ticks" :key="i">
        <line :x1="t.ax" :y1="t.ay" :x2="t.bx" :y2="t.by" :class="{ major: t.major }" />
        <text v-if="t.label" :x="t.lx" :y="t.ly">{{ t.label }}</text>
      </g>
      <path :d="arc" class="bg" pathLength="100" />
      <path :d="arc" class="fg" pathLength="100" :stroke-dasharray="dash" />
    </svg>
    <div class="readout">
      <span class="num big">{{ Math.round(value) }}</span>
      <span class="unit">{{ unit }}</span>
    </div>
  </div>
</template>

<style scoped lang="scss">
.gauge {
  position: relative;
  display: grid;
  place-items: center;
}

svg {
  display: block;
  width: 100%;
  max-width: 230px;
  height: auto;
}

line {
  stroke: var(--cyan-dim);
  stroke-width: 1.5;

  &.major {
    stroke: var(--cyan);
  }
}

text {
  fill: var(--muted);
  font-family: var(--font-num);
  font-size: 8px;
  text-anchor: middle;
}

path {
  fill: none;
  stroke-width: 10;
}

.bg {
  stroke: var(--off);
}

.fg {
  stroke: var(--cyan);
  transition: stroke-dasharray 200ms linear; // lissage entre deux mises à jour (5 par seconde)
}

.readout {
  position: absolute;
  top: 46%;
  left: 0;
  right: 0;
  text-align: center;
  transform: translateY(-50%);

  .unit {
    display: block;
    margin: 4px 0 0;
    letter-spacing: 0.14em;
  }
}
</style>
