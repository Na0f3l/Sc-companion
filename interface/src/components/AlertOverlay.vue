<script setup lang="ts">
// Voile d'alerte plein écran. Toucher / cliquer / Échap le masque (l'interface reste rouge
// tant que la cause est présente).
import { onMounted, onUnmounted } from 'vue'
import { acknowledge, shownAlert } from '@/alerts'

function dismiss(): void {
  if (shownAlert.value) acknowledge(shownAlert.value.id)
}
const onKey = (e: KeyboardEvent) => {
  if (e.key === 'Escape') dismiss()
}
onMounted(() => window.addEventListener('keydown', onKey))
onUnmounted(() => window.removeEventListener('keydown', onKey))
</script>

<template>
  <Transition name="alert">
    <div v-if="shownAlert" class="overlay" :class="`is-${shownAlert.level}`" role="alert" @click="dismiss">
      <div class="band" />
      <div class="box">
        <p class="title">ALERTE !</p>
        <p class="msg">{{ shownAlert.message }}</p>
        <p class="hint">Toucher pour masquer</p>
      </div>
      <div class="band" />
    </div>
  </Transition>
</template>

<style scoped lang="scss">
.overlay {
  --a: var(--red);
  position: fixed;
  inset: 0;
  z-index: 100;
  display: grid;
  grid-template-rows: auto 1fr auto;
  padding: env(safe-area-inset-top, 0) env(safe-area-inset-right, 0) env(safe-area-inset-bottom, 0) env(safe-area-inset-left, 0);
  background: rgb(0 0 0 / 50%);
  // cadre et halo rouges : peints une fois, jamais animés
  box-shadow:
    inset 0 0 0 3px var(--a),
    inset 0 0 140px rgb(255 40 30 / 35%);
  cursor: pointer;

  &.is-warning {
    --a: var(--amber);
  }
}

// bandes de danger hachurées en haut et en bas
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
  // clignotement par paliers d'opacité : quasi aucun calcul
  animation: blink 0.8s steps(2) infinite;
}

.msg {
  color: var(--a);
  font-family: var(--font-ui);
  font-size: clamp(18px, 4.5vw, 34px);
  font-weight: 600;
  letter-spacing: 0.2em;
  text-transform: uppercase;
}

.hint {
  @include label;
  margin-top: 18px;
  color: rgb(255 255 255 / 45%);
}

@keyframes blink {
  50% {
    opacity: 0.35;
  }
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
