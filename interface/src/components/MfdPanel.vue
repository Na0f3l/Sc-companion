<script setup lang="ts">
// Cadre d'écran MFD : titre, champ de télémétrie source, contenu libre (slot) et onglet en bas.
defineProps<{
  title: string
  tab: string
  source?: string // ex. 'flight.instruments' : le champ qui alimente l'écran
}>()
const DEV = import.meta.env.DEV
</script>

<template>
  <!-- pas de titre affiché : l'onglet du bas nomme déjà l'écran ; le titre reste pour les lecteurs d'écran -->
  <article class="mfd" :aria-label="title">
    <div class="inner">
      <!-- champ source : aide au développement, affiché seulement avec le serveur Vite (npm run dev), jamais dans la version compilée -->
      <code v-if="DEV && source">{{ source }}</code>
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

code {
  @include numeric;
  margin-bottom: -6px;
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

// Téléphone : marges réduites, onglet du bas compact (seul nom de l'écran), pas de champ source
@include phone {
  .inner {
    gap: 8px;
    padding: 8px 10px 0;
  }

  .body {
    gap: 8px;
  }

  footer {
    margin: 0 -10px;
    padding: 4px 10px 4px calc(10px + 0.2em);
    font-size: 11px;
  }

  code {
    display: none;
  }
}
</style>
