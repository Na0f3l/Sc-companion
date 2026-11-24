<script setup lang="ts">
// Page principale : choisit les écrans selon le contexte du personnage (à pied / aux commandes).
import { computed, onMounted, watchEffect } from 'vue'
import { ACT, VEH, connect, demo, demoView, exitDemo, has, link, showDemo, source, str } from './telemetry'
import { alertLevel } from './alerts'
import { soundOn, soundUnlocked, toggleSound } from './sound'
import './hit' // flash rouge 0,2 s quand on prend des dégâts
import AppMenu from './components/AppMenu.vue'
import FlightView from './views/FlightView.vue'
import FootView from './views/FootView.vue'
import AlertOverlay from './components/AlertOverlay.vue'
import IdleScreen, { type IdleKind } from './components/IdleScreen.vue'
import MemoryBar from './components/MemoryBar.vue'
import Marquee from './components/Marquee.vue'

// ?demo dans l'adresse : ouvre directement le mode démo (lien à partager, page hébergée sans service)
onMounted(() => (new URLSearchParams(location.search).has('demo') ? showDemo('ship') : connect()))

// Teinte globale : un attribut sur <html>, les variables CSS font le reste
watchEffect(() => {
  document.documentElement.dataset.alert = alertLevel.value ?? ''
})

// Mode de jeu (lu dans le Game.log par le service) : pu, ac ou menu. En AC, l'interface passe au rouge.
const gameMode = computed(() => str('game.mode'))
const MODE_LABEL: Record<string, string> = { pu: 'PU', ac: 'Arena Commander', menu: 'Menu' }
watchEffect(() => {
  document.documentElement.dataset.mode = gameMode.value
})

// Contexte affiché, du plus « bloquant » au plus précis :
//  service injoignable → jeu non lancé → menu → chargement → à pied / en vol
const ctx = computed<'vol' | 'pied' | IdleKind>(() => {
  if (demo.value) return demoView.value === 'ship' ? 'vol' : 'pied'
  if (link.value !== 'online') return 'link'
  if (!has('sc.private_mb')) return 'offline' // StarCitizen.exe absent (mesuré par le service)
  if (str('game.mode') === 'menu') return 'menu'
  if (!has(`${ACT}state.locomotion`)) return 'loading'
  const seated = str(`${ACT}state.locomotion`).endsWith('SEATED')
  return seated && has(`${VEH}class_name`) ? 'vol' : 'pied'
})
const IDLE_LABEL: Record<string, string> = { link: 'No link', offline: 'Game not running', menu: 'Main menu', loading: 'Loading' }
const idle = computed(() => (ctx.value === 'vol' || ctx.value === 'pied' ? null : ctx.value))
const ship = computed(() => str(`${VEH}class_name`).replaceAll('_', ' '))

const TABS = [
  { view: 'foot', ctx: 'pied', label: 'On foot' },
  { view: 'ship', ctx: 'vol', label: 'Ship' },
] as const
</script>

<template>
  <main class="page">
    <header class="top">
      <div class="brand">SC COMPANION</div>
      <div class="ctx" aria-live="polite">
        <span class="dot" :class="{ off: link !== 'online' }" />
        <template v-if="ctx === 'vol'"><b>In flight</b><span class="sep">·</span><Marquee :text="ship" /></template>
        <template v-else-if="ctx === 'pied'"><b>On foot</b><span class="sep">·</span><span>Character</span></template>
        <template v-else>{{ IDLE_LABEL[ctx] }}</template>
      </div>
      <span v-if="gameMode" class="gmode" :class="gameMode">{{ MODE_LABEL[gameMode] }}</span>
      <!-- groupe de droite : reste collé à droite, même quand l'en-tête passe sur deux lignes -->
      <div class="right">
        <div v-if="!demo" class="feed">{{ link }}<template v-if="source"> · {{ source === 'replay' ? 'capture replay' : 'live game' }}</template></div>
        <button v-if="demo" type="button" class="test call" @click="exitDemo">Exit preview</button>
        <!-- le premier clic sur la page déverrouille l'audio ; ce bouton sert aussi à couper / remettre le son -->
        <button
          type="button"
          class="test"
          :class="{ call: soundOn && !soundUnlocked }"
          @click="soundUnlocked && toggleSound()"
        >
          {{ !soundOn ? 'Sound off' : soundUnlocked ? 'Sound on' : 'Click to enable sound' }}
        </button>
        <AppMenu />
      </div>
    </header>

    <AlertOverlay />
    <MemoryBar />

    <!-- Onglets : en direct, ils suivent le jeu (siège pilote / à pied) ; en démo, on choisit -->
    <nav v-if="!idle" class="tabs" :class="{ auto: !demo }" aria-label="Screens">
      <button
        v-for="t in TABS"
        :key="t.view"
        type="button"
        class="tab"
        :class="{ on: ctx === t.ctx }"
        :aria-current="ctx === t.ctx ? 'page' : undefined"
        :disabled="!demo"
        @click="showDemo(t.view)"
      >
        {{ t.label }}
      </button>
      <span v-if="!demo" class="tabs-hint">Follows the game</span>
    </nav>

    <!-- Transition : l'ancien écran s'efface, le nouveau apparaît (opacity uniquement) -->
    <Transition name="swap" mode="out-in">
      <FlightView v-if="ctx === 'vol'" />
      <FootView v-else-if="ctx === 'pied'" />
      <IdleScreen v-else-if="idle" :key="idle" :kind="idle" @demo="showDemo('ship')" />
    </Transition>
  </main>
</template>

<style scoped lang="scss">
.page {
  display: grid;
  gap: 18px;
  max-width: 1180px;
  margin: 0 auto;
  // en bas : la place de la bande mémoire fixe (50 px) + marge
  padding: 20px max(16px, env(safe-area-inset-right)) 80px max(16px, env(safe-area-inset-left));
}

// Une seule ligne : le contexte (nom du vaisseau) rétrécit et défile plutôt que de pousser
// le menu à la ligne. Sous 760 px, l'en-tête passe sur deux lignes (le groupe de droite reste à droite).
.top {
  display: flex;
  align-items: center;
  gap: 12px 20px;

  > * {
    flex: none;
  }

  @media (max-width: 760px) {
    flex-wrap: wrap;
  }
}

// boutons et menu toujours collés à droite
.right {
  display: flex;
  align-items: center;
  gap: 12px 20px;
  margin-left: auto;
}

.brand {
  @include numeric;
  color: var(--cyan);
  font-size: 15px;
  font-weight: 700;
  letter-spacing: 0.18em;

  // une ligne et vraiment peu de place : le titre cède sa place au nom du vaisseau
  @media (min-width: 761px) and (max-width: 900px) {
    display: none;
  }
}

.ctx {
  display: inline-flex;
  align-items: center;
  gap: 10px;
  padding: 6px 14px;
  border: 1px solid var(--cyan-dim);
  background: var(--panel);
  font-size: 13px;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  white-space: nowrap;

  // Largeur du nom du vaisseau avant défilement (voir Marquee) : 200 px, puis 110 px sous 960 px
  // pour garder le titre sur la même ligne (le nom défile alors, même un nom court comme le F7A).
  @media (max-width: 960px) {
    --marquee-max: 110px;
  }
  @include bevel(8px);

  // seul élément de l'en-tête qui rétrécit (le nom du vaisseau défile, voir Marquee)
  .top > & {
    flex: 0 1 auto;
    min-width: 0;
    max-width: 100%;
  }

  > :not(.marquee) {
    flex: none;
  }

  b {
    color: var(--cyan);
    font-weight: 600;
  }
}

.dot {
  width: 8px;
  height: 8px;
  background: var(--cyan);

  &.off {
    background: var(--red);
  }
}

.gmode {
  padding: 3px 8px;
  border: 1px solid var(--cyan-dim);
  color: var(--cyan);
  font: 600 11px var(--font-num);
  letter-spacing: 0.14em;
  text-transform: uppercase;
}

.feed {
  @include numeric;
  color: var(--muted);
  font-size: 12px;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  white-space: nowrap;

  // information secondaire : cédée en premier quand la place manque
  @media (max-width: 900px) {
    display: none;
  }
}

.test {
  padding: 5px 10px;
  border: 1px solid var(--line);
  background: var(--panel);
  color: var(--muted);
  font: 500 11px var(--font-ui);
  letter-spacing: 0.08em;
  text-transform: uppercase;
  cursor: pointer;

  &:hover:not(:disabled) {
    border-color: var(--cyan-dim);
    color: var(--cyan);
  }

  &:disabled {
    opacity: 0.5;
    cursor: default;
  }

  // son pas encore déverrouillé : bouton mis en avant
  &.call {
    border-color: var(--amber);
    color: var(--amber);
  }

  &:focus-visible {
    outline: 2px solid var(--amber);
    outline-offset: 2px;
  }
}

// Onglets d'écran : biseautés comme le reste ; en direct ils ne sont qu'indicateurs (désactivés)
.tabs {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: -6px;
}

.tab {
  @include bevel(8px);
  min-width: 120px;
  padding: 7px 18px;
  border: 1px solid var(--line);
  background: var(--panel);
  color: var(--muted);
  font: 600 12px var(--font-num);
  letter-spacing: 0.16em;
  text-transform: uppercase;
  cursor: pointer;
  transition: color 0.2s, border-color 0.2s, background-color 0.2s;

  &:hover:not(:disabled) {
    border-color: var(--cyan-dim);
    color: var(--text);
  }

  &.on {
    border-color: var(--cyan);
    background: color-mix(in srgb, var(--cyan) 14%, var(--panel));
    color: var(--cyan);
  }

  &:disabled {
    cursor: default;
  }

  &:focus-visible {
    outline: 2px solid var(--amber);
    outline-offset: 2px;
  }
}

.auto .tab:not(.on) {
  opacity: 0.55;
}

.tabs-hint {
  @include label;
  margin-left: 6px;
  font-size: 10px;
}

.swap-enter-active,
.swap-leave-active {
  transition: opacity 0.2s;
}

.swap-enter-from,
.swap-leave-to {
  opacity: 0;
}
</style>
