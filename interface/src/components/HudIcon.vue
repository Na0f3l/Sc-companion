<script setup lang="ts">
// Pictos du HUD, dessinés en SVG (grille 24×24) pour rester proches de ceux du jeu.
// Couleur = currentColor : le parent choisit la teinte.
defineProps<{
  name: 'body-temp' | 'heart' | 'pills' | 'gravity' | 'lungs' | 'pressure' | 'ext-temp' | 'radiation'
}>()
</script>

<template>
  <svg viewBox="0 0 24 24" class="hud-icon" aria-hidden="true">
    <!-- silhouette + thermomètre -->
    <g v-if="name === 'body-temp'">
      <circle cx="7" cy="4.5" r="2" class="f" />
      <path d="M7 8v6.5M4 10.5l3-2.5 3 2.5M5.5 21l1.5-6.5L8.5 21" />
      <path d="M16 3.5a1.5 1.5 0 0 1 3 0v10a3 3 0 1 1-3 0z" />
      <path d="M17.5 8v7.5" class="hot" />
    </g>
    <!-- crochets + tracé ECG -->
    <path v-else-if="name === 'heart'" d="M5 4H3v16h2M19 4h2v16h-2M5 13h3l2-6 2.5 10 2-7 1.2 3H19" />
    <!-- gélule -->
    <g v-else-if="name === 'pills'">
      <path d="M8.2 16.8l8.6-8.6a2.9 2.9 0 0 0-4.1-4.1l-8.6 8.6a2.9 2.9 0 0 0 4.1 4.1z" />
      <path d="M8.5 8.4l4.1 4.1" />
    </g>
    <!-- personnage bras levés sur une balance, flèche vers le bas -->
    <g v-else-if="name === 'gravity'">
      <circle cx="13" cy="3.5" r="2" class="f" />
      <path d="M13 6.5v7M8.5 4.5l4.5 3.5 4.5-3.5M10 19.5l3-6 3 6M6.5 21.5h13M4 8v7.5M2.3 13.8 4 15.5l1.7-1.7" />
    </g>
    <!-- poumons -->
    <g v-else-if="name === 'lungs'">
      <path d="M12 3v8.5M12 9.5c-.8 1.4-2.2 2-2.2 2M12 9.5c.8 1.4 2.2 2 2.2 2" />
      <path d="M9 6.5c-3 1.2-5 5.5-5 10.5 0 2 1 3 2.6 3S10 19 10 17.4V9.5" class="f soft" />
      <path d="M15 6.5c3 1.2 5 5.5 5 10.5 0 2-1 3-2.6 3S14 19 14 17.4V9.5" class="f soft" />
    </g>
    <!-- quatre flèches convergentes (compression) -->
    <path
      v-else-if="name === 'pressure'"
      d="M12 3v6M9.8 6.8 12 9l2.2-2.2M12 21v-6M9.8 17.2 12 15l2.2 2.2M3 12h6M6.8 9.8 9 12l-2.2 2.2M21 12h-6M17.2 9.8 15 12l2.2 2.2"
    />
    <!-- planète + thermomètre -->
    <g v-else-if="name === 'ext-temp'">
      <circle cx="12" cy="12" r="8" />
      <path d="M11 7.5v6a2 2 0 1 0 2 0v-6a1 1 0 0 0-2 0z" />
    </g>
    <!-- trèfle radioactif -->
    <g v-else-if="name === 'radiation'" class="f">
      <circle cx="12" cy="12" r="1.6" />
      <path d="M10.5 9.4 7.5 4.2a9 9 0 0 1 9 0l-3 5.2a3 3 0 0 0-3 0z" />
      <path d="M10.5 9.4 7.5 4.2a9 9 0 0 1 9 0l-3 5.2a3 3 0 0 0-3 0z" transform="rotate(120 12 12)" />
      <path d="M10.5 9.4 7.5 4.2a9 9 0 0 1 9 0l-3 5.2a3 3 0 0 0-3 0z" transform="rotate(240 12 12)" />
    </g>
  </svg>
</template>

<style scoped lang="scss">
.hud-icon {
  display: block;
  width: 100%;
  height: 100%;
  fill: none;
  stroke: currentColor;
  stroke-width: 1.7;
  stroke-linecap: round;
  stroke-linejoin: round;
}

.f {
  fill: currentColor;
}

.soft {
  fill-opacity: 0.85;
  stroke-width: 1.2;
}

.hot {
  stroke: var(--red);
  stroke-width: 2;
}
</style>
