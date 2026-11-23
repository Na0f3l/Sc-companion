<script setup lang="ts">
// Page principale : choisit les écrans selon le contexte du personnage (à pied / aux commandes).
import { computed, onMounted } from 'vue'
import { ACT, VEH, connect, has, link, source, str } from './telemetry'
import FlightView from './views/FlightView.vue'
import FootView from './views/FootView.vue'

onMounted(connect)

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
        <span class="dot" :class="{ off: link !== 'en ligne' }" />
        <template v-if="ctx === 'vol'"><b>En vol</b> · {{ ship }}</template>
        <template v-else-if="ctx === 'pied'"><b>À pied</b> · Personnage</template>
        <template v-else>En attente du jeu…</template>
      </div>
      <div class="feed">{{ link }}<template v-if="source"> · {{ source === 'replay' ? 'rejeu de capture' : source }}</template></div>
    </header>

    <!-- Transition : l'ancien écran s'efface, le nouveau apparaît (opacity uniquement) -->
    <Transition name="swap" mode="out-in">
      <FlightView v-if="ctx === 'vol'" />
      <FootView v-else-if="ctx === 'pied'" />
      <p v-else class="wait">
        Aucune donnée pour l'instant. Le service doit tourner, et le jeu doit être lancé avec le personnage en jeu.
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
