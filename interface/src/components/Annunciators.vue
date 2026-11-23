<script setup lang="ts">
// Les 10 voyants d'alerte du vaisseau : éteint / normal / mineur (orange) / majeur (rouge clignotant).
import { str, VEH } from '@/telemetry'

const LIST = [
  ['pwr', 'Power'], ['wpn', 'Weapons'], ['thr', 'Thrust'], ['shld', 'Shields'], ['cool', 'Cooling'],
  ['qdrv', 'Quantum'], ['radr', 'Radar'], ['prox', 'Proximity'], ['hit', 'Hit'], ['misl', 'Missile'],
] as const

const SHORT: Record<string, string> = {
  ANNUNCIATOR_STATE_NOMINAL: 'nominal',
  ANNUNCIATOR_STATE_MINOR_ON: 'minor',
  ANNUNCIATOR_STATE_MAJOR_ON: 'major',
}
const stateOf = (k: string) => SHORT[str(`${VEH}annunciators.${k}`)] ?? 'off'
</script>

<template>
  <div class="ann">
    <div v-for="[k, fr] in LIST" :key="k" :data-s="stateOf(k)">
      <b>{{ k.toUpperCase() }}</b>
      <small>{{ fr }}</small>
    </div>
  </div>
</template>

<style scoped lang="scss">
.ann {
  display: grid;
  grid-template-columns: repeat(5, 1fr);
  gap: 6px;

  > div {
    display: grid;
    place-items: center;
    gap: 2px;
    padding: 8px 2px;
    border: 1px solid var(--line);
    background: var(--panel);
    color: var(--cyan-dim);
    text-align: center;
  }
}

b {
  font: 600 13px var(--font-num);
  letter-spacing: 0.08em;
}

small {
  font-size: 9px;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  opacity: 0.8;
}

[data-s='off'] {
  opacity: 0.45;
}

[data-s='nominal'] {
  color: var(--cyan);
  border-color: var(--cyan-dim);
}

[data-s='minor'] {
  color: var(--bg);
  background: var(--amber);
  border-color: var(--amber);
}

// Clignotement par opacity + steps : pas d'interpolation, très peu de calcul.
[data-s='major'] {
  color: #fff;
  background: var(--red);
  border-color: var(--red);
  animation: blink 0.5s steps(2) infinite;
}

@keyframes blink {
  50% {
    opacity: 0.45;
  }
}
</style>
