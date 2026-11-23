<script setup lang="ts">
// Barre verticale façon HUD du jeu (vitesse, boost) : un tube gradué, des zones de couleur
// fixes (vert / jaune / rouge…), une valeur et un libellé dessous.
//
// Rendu léger : le dégradé des zones est peint une fois ; la partie « vide » est un cache
// qu'on rétrécit avec transform: scaleY (animé par la carte graphique, transition 200 ms).
// En mode `reverse` (marche arrière), la barre est bleue et se remplit du haut vers le bas.
import { computed } from 'vue'

export interface Zone {
  to: number // fin de la zone, de 0 à 1 (la première commence à 0)
  color: string
}

const props = withDefaults(
  defineProps<{
    value: number // 0 → 1
    zones: Zone[]
    reading: string // valeur affichée sous la barre
    label: string
    reverse?: boolean
    disabled?: boolean
  }>(),
  { reverse: false, disabled: false },
)

const fill = computed(() => {
  if (props.reverse) return 'linear-gradient(to bottom, #60a5fa, #2563eb)'
  let from = 0
  const stops = props.zones.map((z) => {
    const s = `${z.color} ${from * 100}% ${z.to * 100}%`
    from = z.to
    return s
  })
  return `linear-gradient(to top, ${stops.join(', ')})`
})

const cover = computed(() => `scaleY(${1 - Math.min(1, Math.max(0, props.value))})`)
</script>

<template>
  <div class="vbar" :class="{ reverse, disabled }">
    <div class="tube">
      <div class="fill" :style="{ background: fill }" />
      <div class="cover" :style="{ transform: cover }" />
      <div class="ticks" />
    </div>
    <span class="reading">{{ reading }}</span>
    <span class="label">{{ label }}</span>
    <slot />
  </div>
</template>

<style scoped lang="scss">
.vbar {
  display: grid;
  justify-items: center;
  gap: 4px;
  min-width: 0;
}

.tube {
  position: relative;
  width: 16px;
  height: var(--vbar-h, 150px);
  overflow: hidden;
  border: 1px solid var(--cyan-dim);
  background: var(--off);
}

.fill,
.cover,
.ticks {
  position: absolute;
  inset: 0;
}

// Le cache laisse deviner les zones en transparence, comme le tube vide du jeu
.cover {
  background: rgb(3 16 20 / 82%);
  transform-origin: top; // la valeur monte depuis le bas
  transition: transform 200ms linear;
}

.reverse .cover {
  transform-origin: bottom; // marche arrière : la valeur descend depuis le haut
}

// graduations horizontales fines, peintes une fois
.ticks {
  background: repeating-linear-gradient(to top, transparent 0 3px, rgb(0 0 0 / 45%) 3px 4px);
}

.reading {
  @include numeric;
  margin-top: 4px;
  color: var(--text);
  font-size: 20px;
  font-weight: 600;
}

.reverse .reading {
  color: #60a5fa;
}

.label {
  @include label;
  font-size: 10px;
}

.disabled {
  opacity: 0.35;
}
</style>
