<script setup lang="ts">
// Voile d'alerte plein écran : apparaît, le fond clignote 2 fois, reste 3 s, disparaît seul.
// Aucune interaction nécessaire (pointer-events: none : il ne bloque jamais l'écran).
import { shownAlert } from '@/alerts'
</script>

<template>
  <Transition name="alert">
    <!-- :key = l'id : une nouvelle alerte relance l'animation de clignotement -->
    <div v-if="shownAlert" :key="shownAlert.id" class="overlay" :class="`is-${shownAlert.level}`" role="alert">
      <div class="band" />
      <div class="box">
        <p class="title">ALERTE !</p>
        <p class="msg">{{ shownAlert.message }}</p>
      </div>
      <div class="band" />
    </div>
  </Transition>
</template>

<style scoped lang="scss">
.overlay {
  --a: var(--red);
  --glow: 255 40 30;
  position: fixed;
  inset: 0;
  z-index: 100;
  display: grid;
  grid-template-rows: auto 1fr auto;
  padding: env(safe-area-inset-top, 0) env(safe-area-inset-right, 0) env(safe-area-inset-bottom, 0) env(safe-area-inset-left, 0);
  background: rgb(0 0 0 / 55%);
  box-shadow: inset 0 0 0 3px var(--a);
  pointer-events: none;

  &.is-warning {
    --a: var(--amber);
    --glow: 242 194 59;
  }

  // Calque coloré qui « bat » : dense sur les bords, plus léger au centre pour garder le texte lisible.
  // Seule son opacité est animée : la carte graphique s'en charge, sans repeindre la page.
  &::before {
    content: '';
    position: absolute;
    inset: 0;
    z-index: -1;
    background: radial-gradient(ellipse at center, rgb(var(--glow) / 25%) 0%, rgb(var(--glow) / 70%) 100%);
    animation: pulse 0.5s ease-out infinite; // 6 battements pendant les 3 s
  }
}

@keyframes pulse {
  0% {
    opacity: 1;
  }

  100% {
    opacity: 0.15;
  }
}

.band {
  height: 14px;
  background: repeating-linear-gradient(-45deg, var(--a) 0 14px, transparent 14px 28px);
  opacity: 0.7;
}

.box {
  display: grid;
  place-content: center;
  justify-items: center;
  gap: 10px;
  padding: 0 16px;
  text-align: center;
}

p {
  margin: 0;
}

.title {
  @include numeric;
  color: var(--a);
  font-size: clamp(40px, 12vw, 110px);
  font-weight: 700;
  line-height: 1;
  letter-spacing: 0.12em;
  text-shadow: 0 0 24px rgb(0 0 0 / 80%); // lisible même au plus fort du battement
  animation: punch 0.35s ease-out; // petit « coup » à l'apparition (transform uniquement)
}

@keyframes punch {
  from {
    transform: scale(1.25);
  }
}

.msg {
  color: var(--a);
  font-family: var(--font-ui);
  font-size: clamp(18px, 4.5vw, 34px);
  font-weight: 600;
  letter-spacing: 0.2em;
  text-transform: uppercase;
}

.alert-enter-active,
.alert-leave-active {
  transition: opacity 0.15s;
}

.alert-enter-from,
.alert-leave-to {
  opacity: 0;
}
</style>
