<script setup lang="ts">
// Jauge en arc de 270° ouverte en bas (O₂, drogues dans le HUD du jeu), contenu libre au centre.
import { computed } from 'vue'

const props = withDefaults(defineProps<{ value: number; color?: string }>(), { color: 'var(--cyan)' })
// pathLength=100 sur un cercle entier : 270° = 75 unités
const dash = computed(() => `${Math.min(1, Math.max(0, props.value)) * 75} 100`)
</script>

<template>
  <div class="arc">
    <svg viewBox="0 0 64 64" aria-hidden="true">
      <circle class="track" cx="32" cy="32" r="27" pathLength="100" stroke-dasharray="75 100" />
      <circle class="fill" cx="32" cy="32" r="27" pathLength="100" :stroke-dasharray="dash" :style="{ stroke: color }" />
    </svg>
    <div class="center"><slot /></div>
  </div>
</template>

<style scoped lang="scss">
.arc {
  position: relative;
  width: 100%;
  height: 100%;
}

svg {
  display: block;
  width: 100%;
  height: 100%;
}

circle {
  fill: none;
  stroke-width: 5;
  stroke-linecap: round;
  transform: rotate(135deg); // départ en bas à gauche
  transform-origin: 32px 32px;
}

.track {
  stroke: var(--off);
}

.fill {
  transition: stroke-dasharray 200ms linear;
}

.center {
  position: absolute;
  inset: 22%;
  display: grid;
  place-items: center;
  color: inherit; // prend la couleur d'état de la tuile
}
</style>
