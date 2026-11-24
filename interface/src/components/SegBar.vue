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
    // zone fixe en rouge en bas de la barre (ex. 0.25 pour le boost : en dessous, pas de nouveau boost possible)
    dangerBelow?: number
  }>(),
  { segments: 10, vertical: false, alert: 'low', dangerBelow: 0 },
)

// nombre de segments de la zone rouge (arrondi au segment près)
const dangerCount = computed(() => Math.round(props.dangerBelow * props.segments))

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
    <i v-for="i in segments" :key="i" :class="{ on: i <= lit, danger: i <= dangerCount }" />
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
  @include bevel-edges(4px);
  position: relative;

  &.on {
    background: var(--c);
    border-color: var(--c);
  }
}

// zone rouge fixe : allumée en rouge, et contour rouge même éteinte pour qu'on la voie arriver
i.danger {
  --c: var(--red);
  border-color: rgb(255 91 79 / 45%);
}

.is-warn i {
  --c: var(--amber);
}

.is-crit i {
  --c: var(--red);
}

// Téléphone : jauges verticales plus courtes (12 segments de 6 px au lieu de 9)
@include phone {
  .seg.is-v i {
    height: 6px;
  }

  .seg.is-v {
    gap: 2px;
    width: 24px;
  }
}
</style>
