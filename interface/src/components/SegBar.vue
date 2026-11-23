<script setup lang="ts">
// Barre segmentée façon « gestion d'énergie » du jeu.
// Reçoit une valeur entre 0 et 1 et allume le nombre de segments correspondant.
import { computed } from 'vue'

type Level = 'ok' | 'warn' | 'crit'

const props = withDefaults(
  defineProps<{
    value: number // 0 → 1
    segments?: number
    vertical?: boolean
    // 'low' : alerte quand la valeur est basse (carburant, santé)
    // 'high' : alerte quand elle est haute (charge G, température)
    // 'none' : jamais d'alerte
    alert?: 'low' | 'high' | 'none'
  }>(),
  { segments: 10, vertical: false, alert: 'low' },
)

// computed : recalculé automatiquement, et seulement quand props.value ou props.segments changent.
const lit = computed(() => Math.round(Math.min(1, Math.max(0, props.value)) * props.segments))

const level = computed<Level>(() => {
  const v = props.value
  if (props.alert === 'low') return v < 0.15 ? 'crit' : v < 0.3 ? 'warn' : 'ok'
  if (props.alert === 'high') return v > 0.8 ? 'crit' : v > 0.55 ? 'warn' : 'ok'
  return 'ok'
})
</script>

<template>
  <div
    class="seg"
    :class="[vertical ? 'is-v' : 'is-h', `is-${level}`]"
    role="meter"
    :aria-valuenow="Math.round(value * 100)"
    aria-valuemin="0"
    aria-valuemax="100"
  >
    <!-- v-for sur un nombre : i va de 1 à segments -->
    <i v-for="i in segments" :key="i" :class="{ on: i <= lit }" />
  </div>
</template>

<style scoped lang="scss">
.seg {
  display: flex;
  gap: 3px;

  &.is-v {
    flex-direction: column-reverse; // le 1er segment en bas
    width: 30px;

    i {
      height: 9px;
    }
  }

  &.is-h {
    width: 100%;

    i {
      flex: 1;
      height: 14px;
    }
  }
}

i {
  --c: var(--cyan);
  display: block;
  background: var(--off);
  border: 1px solid var(--line);
  @include bevel(4px);

  &.on {
    background: var(--c);
    border-color: var(--c);
  }
}

.is-warn i {
  --c: var(--amber);
}

.is-crit i {
  --c: var(--red);
}
</style>
