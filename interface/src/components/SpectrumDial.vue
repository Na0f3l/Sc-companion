<script setup lang="ts">
// Demi-arc dégradé (bleu → vert → jaune → rouge) avec un repère, comme pression / température / radiations
// dans le HUD du jeu. Le dégradé est peint une fois ; seul le repère tourne (transform).
import { computed } from 'vue'

const props = defineProps<{ value: number }>() // 0 → 1 : 0 en bas (bleu), 1 en haut (rouge)
const angle = computed(() => `rotate(${180 - Math.min(1, Math.max(0, props.value)) * 180}deg)`)
</script>

<template>
  <div class="dial">
    <div class="spectrum" />
    <div class="needle" :style="{ transform: angle }"><i /></div>
    <div class="icon"><slot /></div>
  </div>
</template>

<style scoped lang="scss">
.dial {
  position: relative;
  width: 100%;
  height: 100%;
}

// Anneau : dégradé conique sur la moitié droite, évidé au centre par un masque radial.
.spectrum {
  position: absolute;
  inset: 0;
  border-radius: 50%;
  background: conic-gradient(#ef4444 0deg, #f59e0b 45deg, #facc15 80deg, #57e389 120deg, #3b82f6 180deg, transparent 180deg);
  mask: radial-gradient(circle, transparent 60%, #000 62%, #000 70%, transparent 72%);
}

.needle {
  position: absolute;
  inset: 0;
  transition: transform 200ms linear;

  i {
    position: absolute;
    top: 6%;
    left: 50%;
    width: 2px;
    height: 16%;
    margin-left: -1px;
    background: var(--text);
  }
}

.icon {
  position: absolute;
  inset: 26%;
  color: inherit; // prend la couleur d'état de la tuile
}
</style>
