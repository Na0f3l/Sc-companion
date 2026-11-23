<script setup lang="ts">
// Page principale : choisit les écrans selon le contexte du personnage (à pied / aux commandes).
import { computed, onMounted, watchEffect } from 'vue'
import { ACT, VEH, connect, has, link, source, str } from './telemetry'
import { alertLevel, shownAlert, triggerTest } from './alerts'
import { soundOn, soundUnlocked, toggleSound } from './sound'
import FlightView from './views/FlightView.vue'
import FootView from './views/FootView.vue'
import AlertOverlay from './components/AlertOverlay.vue'

onMounted(connect)

// Teinte globale : un attribut sur <html>, les variables CSS font le reste
watchEffect(() => {
  document.documentElement.dataset.alert = alertLevel.value ?? ''
})

const ctx = computed<'vol' | 'pied' | 'attente'>(() => {
  if (!has(`${ACT}state.locomotion`)) return 'attente'
  const seated = str(`${ACT}state.locomotion`).endsWith('SEATED')
  return seated && has(`${VEH}class_name`) ? 'vol' : 'pied'
})
const ship = computed(() => str(`${VEH}class_name`).replaceAll('_', ' '))
</script>

<template>
  <main class="page">
    <header class="top">
      <div class="brand">SC COMPANION</div>
      <div class="ctx" aria-live="polite">
        <span class="dot" :class="{ off: link !== 'online' }" />
        <template v-if="ctx === 'vol'"><b>In flight</b> · {{ ship }}</template>
        <template v-else-if="ctx === 'pied'"><b>On foot</b> · Character</template>
        <template v-else>Waiting for the game…</template>
      </div>
      <div class="feed">{{ link }}<template v-if="source"> · {{ source === 'replay' ? 'capture replay' : 'live game' }}</template></div>
      <!-- le premier clic sur la page déverrouille l'audio ; ce bouton sert aussi à couper / remettre le son -->
      <button
        type="button"
        class="test"
        :class="{ call: soundOn && !soundUnlocked }"
        @click="soundUnlocked && toggleSound()"
      >
        {{ !soundOn ? 'Sound off' : soundUnlocked ? 'Sound on' : 'Click to enable sound' }}
      </button>
      <button type="button" class="test" :disabled="!!shownAlert" @click="triggerTest">Test alert</button>
    </header>

    <AlertOverlay />

    <!-- Transition : l'ancien écran s'efface, le nouveau apparaît (opacity uniquement) -->
    <Transition name="swap" mode="out-in">
      <FlightView v-if="ctx === 'vol'" />
      <FootView v-else-if="ctx === 'pied'" />
      <p v-else class="wait">
        No data yet. The service must be running and the game launched with your character spawned.
      </p>
    </Transition>
  </main>
</template>

<style scoped lang="scss">
.page {
  display: grid;
  gap: 18px;
  max-width: 1180px;
  margin: 0 auto;
  padding: 20px max(16px, env(safe-area-inset-right)) 32px max(16px, env(safe-area-inset-left));
}

.top {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 12px 20px;
}

.brand {
  @include numeric;
  color: var(--cyan);
  font-size: 15px;
  font-weight: 700;
  letter-spacing: 0.18em;
}

.ctx {
  display: inline-flex;
  align-items: center;
  gap: 10px;
  padding: 6px 14px;
  border: 1px solid var(--cyan-dim);
  background: var(--panel);
  font-size: 13px;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  @include bevel(8px);

  b {
    color: var(--cyan);
    font-weight: 600;
  }
}

.dot {
  width: 8px;
  height: 8px;
  background: var(--cyan);

  &.off {
    background: var(--red);
  }
}

.feed {
  @include numeric;
  margin-left: auto;
  color: var(--muted);
  font-size: 12px;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}

.test {
  padding: 5px 10px;
  border: 1px solid var(--line);
  background: var(--panel);
  color: var(--muted);
  font: 500 11px var(--font-ui);
  letter-spacing: 0.08em;
  text-transform: uppercase;
  cursor: pointer;

  &:hover:not(:disabled) {
    border-color: var(--cyan-dim);
    color: var(--cyan);
  }

  &:disabled {
    opacity: 0.5;
    cursor: default;
  }

  // son pas encore déverrouillé : bouton mis en avant
  &.call {
    border-color: var(--amber);
    color: var(--amber);
  }

  &:focus-visible {
    outline: 2px solid var(--amber);
    outline-offset: 2px;
  }
}

.wait {
  max-width: 60ch;
  color: var(--muted);
  line-height: 1.6;
}

.swap-enter-active,
.swap-leave-active {
  transition: opacity 0.2s;
}

.swap-enter-from,
.swap-leave-to {
  opacity: 0;
}
</style>
