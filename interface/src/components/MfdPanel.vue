<script setup lang="ts">
// Cadre d'écran MFD : titre, champ de télémétrie source, contenu libre (slot) et onglet en bas.
defineProps<{
  title: string
  tab: string
  source?: string // ex. 'flight.instruments' : le champ qui alimente l'écran
}>()
</script>

<template>
  <article class="mfd">
    <div class="inner">
      <header>
        <span class="title">{{ title }}</span>
        <code v-if="source">{{ source }}</code>
      </header>
      <!-- <slot /> : le contenu placé entre <MfdPanel> et </MfdPanel> arrive ici -->
      <div class="body"><slot /></div>
      <footer>{{ tab }}</footer>
    </div>
  </article>
</template>

<style scoped lang="scss">
// Bordure biseautée : clip-path coupe aussi les bordures CSS, donc on empile
// un fond « couleur de trait » et un intérieur décalé de 1px.
.mfd {
  min-width: 0;
  padding: 1px;
  background: var(--line);
  @include bevel;
}

.inner {
  display: flex;
  flex-direction: column;
  gap: 12px;
  height: 100%;
  padding: 14px 14px 0;
  background:
    repeating-linear-gradient(0deg, rgb(99 228 221 / 2.5%) 0 1px, transparent 1px 3px),
    linear-gradient(180deg, var(--panel-2), var(--panel));
  @include bevel;
}

header {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: 8px;
}

.title {
  @include label;
  letter-spacing: 0.14em;
}

code {
  @include numeric;
  font-size: 10px;
  color: var(--cyan-dim);
  overflow-wrap: anywhere;
  text-align: right;
}

.body {
  flex: 1;
  display: grid;
  gap: 12px;
}

footer {
  @include numeric;
  margin: 0 -14px;
  // pas de flèches ◀ ▶ comme dans le jeu : ici elles ne changeraient pas d'écran
  padding: 7px 14px 7px calc(14px + 0.2em); // compense l'espace ajouté après la dernière lettre
  border-top: 1px solid var(--line);
  background: rgb(99 228 221 / 5%);
  color: var(--cyan);
  font-size: 13px;
  font-weight: 600;
  letter-spacing: 0.2em;
  text-align: center;
}
</style>
