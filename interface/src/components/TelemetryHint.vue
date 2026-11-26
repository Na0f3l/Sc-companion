<script setup lang="ts">
// Encart des écrans d'attente : la télémétrie du jeu est-elle allumée ? Sinon, un bouton l'allume (variable
// GRPC_CLIENT_SERVER_ENABLED du compte Windows, écrite par le service), et on dit quoi relancer.
//   svc.grpc_env   variable présente sur le PC (registre)
//   game.grpc_env  le jeu lancé l'a reçue (en-tête du Game.log ; absent = inconnu)
import { computed, ref } from 'vue'
import { has, sendEnableTelemetry, tm } from '@/telemetry'

const props = defineProps<{ running: boolean }>() // jeu lancé
const asked = ref(false) // bouton cliqué sur cet écran

const state = computed<'off' | 'restart' | 'enabled' | null>(() => {
  if (!has('svc.grpc_env')) return null // démo, service ancien
  if (tm['svc.grpc_env'] !== true) return 'off'
  if (props.running && tm['game.grpc_env'] === false) return 'restart' // activée après le lancement du jeu
  if (asked.value && !props.running) return 'enabled'
  return null
})
function enable(): void {
  if (sendEnableTelemetry()) asked.value = true
}
</script>

<template>
  <div v-if="state" class="tlm" :class="state">
    <template v-if="state === 'off'">
      <p><b>Game telemetry is off on this PC.</b> The live HUD needs it: one click turns it on for your Windows account.</p>
      <button type="button" @click="enable">Enable game telemetry</button>
    </template>
    <p v-else-if="state === 'restart'">
      <b>Restart needed.</b> Telemetry was turned on after Star Citizen started. Quit the game, quit the RSI Launcher (its
      icon next to the clock › Quit), then start them again.
    </p>
    <p v-else>
      <b>Telemetry enabled.</b> If the RSI Launcher is open, quit it (its icon next to the clock › Quit) and start it again
      before launching the game.
    </p>
  </div>
</template>

<style scoped lang="scss">
.tlm {
  max-width: 420px;
  margin-top: 12px;
  padding: 10px 12px;
  border: 1px solid var(--amber);
  background: color-mix(in srgb, var(--amber) 7%, transparent);
  color: var(--text);
  font: 500 12px/1.45 var(--font-ui);
  letter-spacing: 0.02em;
  text-align: left;

  &.enabled {
    border-color: var(--green);
    background: color-mix(in srgb, var(--green) 7%, transparent);
  }

  p {
    margin: 0;
  }

  b {
    color: var(--amber);
  }

  &.enabled b {
    color: var(--green);
  }

  button {
    margin-top: 8px;
    padding: 6px 12px;
    border: 1px solid var(--amber);
    background: none;
    color: var(--amber);
    font: 600 11px var(--font-ui);
    letter-spacing: 0.08em;
    text-transform: uppercase;
    cursor: pointer;

    &:hover {
      background: color-mix(in srgb, var(--amber) 14%, transparent);
    }

    &:focus-visible {
      outline: 2px solid var(--amber);
      outline-offset: 1px;
    }
  }
}
</style>
