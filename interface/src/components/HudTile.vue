<script setup lang="ts">
// Tuile du HUD : un visuel (picto, jauge…) dans le slot, la valeur dessous, un libellé discret.
// soon : donnée prévue par le jeu mais pas encore envoyée → tuile grisée avec « coming soon » (comme Q-Fuel)
withDefaults(defineProps<{ value: string; label: string; tone?: 'ok' | 'good' | 'warn' | 'crit'; soon?: boolean }>(), {
  tone: 'ok',
  soon: false,
})
</script>

<template>
  <div class="tile" :class="soon ? 'is-soon' : `is-${tone}`">
    <div class="visual"><slot /></div>
    <span class="val">{{ value }}</span>
    <span class="name">{{ label }}</span>
    <span v-if="soon" class="soon">coming soon</span>
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

// Donnée pas encore envoyée par le jeu
.is-soon :is(.visual, .val, .name) {
  opacity: 0.4;
}

.soon {
  @include label;
  font-size: 8px;
  letter-spacing: 0.08em;
}

// L'état colore la valeur ET le picto (le visuel utilise currentColor)
.is-good :is(.val, .visual) {
  color: #57e389;
}

.is-warn :is(.val, .visual) {
  color: var(--amber);
}

.is-crit :is(.val, .visual) {
  color: var(--red);
}
</style>
