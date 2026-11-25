<script setup lang="ts">
// Mini picto d'un événement du jeu (8 × 8, couleur héritée), sous la courbe RAM et dans l'analyse de session :
//   point = lieu, saut quantique…        flèche ↑ / ↓ = montée dans un vaisseau / sortie
//   losange = contrat accepté, crime…     coche / croix = contrat terminé / échoué (ou fuite RAM)
//   croix blanche = contrat abandonné
//   crâne = ennemi abattu (vert) ou mort du joueur (rouge), cerclé quand un joueur est en cause
//   losange rouge = vaisseau du joueur détruit (sans lui à bord)
//   crâne blanc = coma (vie à 0, en attente des secours) ; cœur blanc = ranimé sans être mort entre-temps
// La couleur vient de la classe ev-<niveau> (styles/base.scss).
import { computed } from 'vue'

export type EventLevel =
  | 'info' | 'board' | 'exit' | 'note' | 'success' | 'failure' | 'abandon' | 'kill' | 'killp' | 'death' | 'deathp' | 'loss'
  | 'downed' | 'revived'
export type GameEvent = [number, EventLevel, string] // [ms, niveau, texte]

const props = defineProps<{ level: EventLevel }>()

const SHAPE: Record<EventLevel, string> = {
  info: 'dot', board: 'up', exit: 'down', note: 'diamond', success: 'check', failure: 'cross', abandon: 'cross',
  kill: 'skull', killp: 'skullp', death: 'skull', deathp: 'skullp', loss: 'diamond', downed: 'skull', revived: 'heart',
}
const shape = computed(() => SHAPE[props.level] ?? 'dot') // type inconnu (service plus récent) : un point
</script>

<template>
  <svg class="picto" viewBox="0 0 8 8" aria-hidden="true">
    <path v-if="shape === 'up'" d="M4 .5 7.5 4.5H5.3V7.5H2.7V4.5H.5Z" />
    <path v-else-if="shape === 'down'" d="M4 7.5 7.5 3.5H5.3V.5H2.7V3.5H.5Z" />
    <path v-else-if="shape === 'diamond'" d="M4 1.2 6.8 4 4 6.8 1.2 4Z" />
    <path v-else-if="shape === 'heart'" d="M4 7.1 1.2 4.3C.3 3.4.6 1.4 2.2 1.3 3 1.25 3.6 1.7 4 2.3 4.4 1.7 5 1.25 5.8 1.3 7.4 1.4 7.7 3.4 6.8 4.3Z" />
    <path v-else-if="shape === 'check'" class="stroke" d="M1.2 4.4 3.2 6.5 7.2 1.2" />
    <path v-else-if="shape === 'cross'" class="stroke" d="M1.5 1.5 6.5 6.5M6.5 1.5 1.5 6.5" />
    <!-- crâne : boîte crânienne + mâchoire, yeux et dents évidés -->
    <!-- joueur en cause : crâne dans un anneau (même picto, lisible à 8 px) -->
    <template v-else-if="shape === 'skullp'">
      <circle class="ring" cx="4" cy="4" r="3.7" />
      <path
        fill-rule="evenodd"
        transform="translate(1.4 1.3) scale(.65)"
        d="M4 .4C2 .4.6 1.8.6 3.6c0 1 .5 1.8 1.3 2.2V7.6h4.2V5.8c.8-.4 1.3-1.2 1.3-2.2C7.4 1.8 6 .4 4 .4ZM2.9 2.7a.9.9 0 1 0 0 1.8.9.9 0 0 0 0-1.8Zm2.2 0a.9.9 0 1 0 0 1.8.9.9 0 0 0 0-1.8ZM3.1 6.3v1.3h.5V6.3Zm1.3 0v1.3h.5V6.3Z"
      />
    </template>
    <path
      v-else-if="shape === 'skull'"
      fill-rule="evenodd"
      d="M4 .4C2 .4.6 1.8.6 3.6c0 1 .5 1.8 1.3 2.2V7.6h4.2V5.8c.8-.4 1.3-1.2 1.3-2.2C7.4 1.8 6 .4 4 .4ZM2.9 2.7a.9.9 0 1 0 0 1.8.9.9 0 0 0 0-1.8Zm2.2 0a.9.9 0 1 0 0 1.8.9.9 0 0 0 0-1.8ZM3.1 6.3v1.3h.5V6.3Zm1.3 0v1.3h.5V6.3Z"
    />
    <circle v-else cx="4" cy="4" r="1.6" />
  </svg>
</template>

<style scoped lang="scss">
.picto {
  display: block;
  width: 8px;
  height: 8px;
  fill: currentColor;
}

.ring {
  fill: none;
  stroke: currentColor;
  stroke-width: 0.7;
}

.stroke {
  fill: none;
  stroke: currentColor;
  stroke-width: 1.6;
  stroke-linecap: round;
  stroke-linejoin: round;
}
</style>
