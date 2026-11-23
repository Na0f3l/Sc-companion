<script setup lang="ts">
// Voile d'alerte plein écran : apparaît, le fond bat 3 fois en 1,5 s, puis disparaît seul.
// Aucune interaction nécessaire (pointer-events: none : il ne bloque jamais l'écran).
import { shownAlert } from '@/alerts'
</script>

<template>
  <Transition name="alert">
    <!-- :key = l'id : une nouvelle alerte relance l'animation de clignotement -->
    <div v-if="shownAlert" :key="shownAlert.id" class="overlay" :class="`is-${shownAlert.level}`" role="alert">
      <div class="band" />
      <div class="box">
        <p class="title">ALERTE !</p>
        <p class="msg">{{ shownAlert.message }}</p>
      </div>
      <div class="band" />
    </div>
  </Transition>
</template>

<style scoped lang="scss">
.overlay {
  --a: var(--red);
  --glow: 255 40 30;
  position: fixed;
  inset: 0;
  z-index: 100;
  display: grid;
  grid-template-rows: auto 1fr auto;
  padding: env(safe-area-inset-top, 0) env(safe-area-inset-right, 0) env(safe-area-inset-bottom, 0) env(safe-area-inset-left, 0);
  background: rgb(0 0 0 / 55%);
  box-shadow: inset 0 0 0 3px var(--a);
  pointer-events: none;

  &.is-warning {
    --a: var(--amber);
    --glow: 242 194 59;
  }

  // Calque coloré qui « bat » : dense sur les bords, plus léger au centre pour garder le texte lisible.
  // Seule son opacité est animée : la carte graphique s'en charge, sans repeindre la page.
  &::before {
    content: '';
    position: absolute;
    inset: 0;
    z-index: -1;
    background: radial-gradient(ellipse at center, rgb(var(--glow) / 25%) 0%, rgb(var(--glow) / 70%) 100%);
    // 3 battements = 1,5 s = DISPLAY_MS ; « forwards » : reste sur le dernier état (atténué)
    // au lieu de revenir à pleine intensité juste avant la sortie
    animation: pulse 0.5s ease-out 3 forwards;
  }
}

@keyframes pulse {
  0% {
    opacity: 1;
  }

  100% {
    opacity: 0.15;
  }
}

.band {
  height: 14px;
  background: repeating-linear-gradient(-45deg, var(--a) 0 14px, transparent 14px 28px);
  opacity: 0.7;
}

.box {
  display: grid;
  place-content: center;
  justify-items: center;
  gap: 10px;
  padding: 0 16px;
  text-align: center;
}

p {
  margin: 0;
}

.title {
  @include numeric;
  color: var(--a);
  font-size: clamp(40px, 12vw, 110px);
  font-weight: 700;
  line-height: 1;
  letter-spacing: 0.12em;
  text-shadow: 0 0 24px rgb(0 0 0 / 80%); // lisible même au plus fort du battement
  animation: punch 0.35s ease-out; // petit « coup » à l'apparition (transform uniquement)
}

@keyframes punch {
  from {
    transform: scale(1.25);
  }
}

.msg {
  color: var(--a);
  font-family: var(--font-ui);
  font-size: clamp(18px, 4.5vw, 34px);
  font-weight: 600;
  letter-spacing: 0.2em;
  text-transform: uppercase;
}

// Entrée : fondu rapide (le titre a son propre « coup », voir .title)
.alert-enter-active {
  transition: opacity 0.15s;
}

.alert-enter-from {
  opacity: 0;
}

// Sortie : inverse de l'intro. Le voile s'estompe, le texte repart vers l'avant
// (il grossit en s'effaçant). Uniquement opacity / transform.
.alert-leave-active {
  transition: opacity 0.4s ease-in;

  .title,
  .msg {
    transition:
      transform 0.4s ease-in,
      opacity 0.4s ease-in;
  }
}

.alert-leave-to {
  opacity: 0;

  .title {
    transform: scale(1.5);
    opacity: 0;
  }

  .msg {
    transform: scale(1.2);
    opacity: 0;
  }
}
</style>
