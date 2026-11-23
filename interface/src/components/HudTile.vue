<script setup lang="ts">
// Tuile du HUD : un visuel (picto, jauge…) dans le slot, la valeur dessous, un libellé discret.
withDefaults(defineProps<{ value: string; label: string; tone?: 'ok' | 'good' | 'warn' | 'crit' }>(), { tone: 'ok' })
</script>

<template>
  <div class="tile" :class="`is-${tone}`">
    <div class="visual"><slot /></div>
    <span class="val">{{ value }}</span>
    <span class="name">{{ label }}</span>
  </div>
</template>

<style scoped lang="scss">
.tile {
  display: grid;
  justify-items: center;
  align-content: start;
  gap: 4px;
  min-width: 0;
  padding: 10px 4px 8px;
  border: 1px solid var(--line);
  background: rgb(99 228 221 / 3%);
  color: var(--text);
  @include bevel(6px);
}

.visual {
  display: grid;
  place-items: center;
  width: 100%;
  max-width: 52px;
  aspect-ratio: 1;
}

.val {
  @include numeric;
  font-size: 15px;
  font-weight: 600;
  white-space: nowrap;
}

.name {
  @include label;
  font-size: 9px;
  text-align: center;
}

.is-good .val {
  color: #57e389;
}

.is-warn .val {
  color: var(--amber);
}

.is-crit .val {
  color: var(--red);
}
</style>
