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
  --flash: rgb(255 40 30 / 45%);
  position: fixed;
  inset: 0;
  z-index: 100;
  display: grid;
  grid-template-rows: auto 1fr auto;
  padding: env(safe-area-inset-top, 0) env(safe-area-inset-right, 0) env(safe-area-inset-bottom, 0) env(safe-area-inset-left, 0);
  background: rgb(0 0 0 / 50%);
  box-shadow:
    inset 0 0 0 3px var(--a),
    inset 0 0 140px rgb(255 40 30 / 35%);
  pointer-events: none;
  // 2 clignotements du fond (rouge / sombre), puis il reste sombre
  animation: flash 0.5s steps(1) 2;

  &.is-warning {
    --a: var(--amber);
    --flash: rgb(242 194 59 / 40%);
  }
}

@keyframes flash {
  0% {
    background: var(--flash);
  }

  50% {
    background: rgb(0 0 0 / 50%);
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
