<script setup lang="ts">
// Page principale : choisit les écrans selon le contexte du personnage (à pied / aux commandes).
import { computed, onMounted, ref, watch, watchEffect } from 'vue'
import { ACT, VEH, connect, demo, demoView, exitDemo, has, link, showDemo, source, str } from './telemetry'
import { alertLevel } from './alerts'
import { soundOn, soundUnlocked, toggleSound } from './sound'
import './hit' // flash rouge 0,2 s quand on prend des dégâts
import './wakelock' // garder l'écran allumé (réglage du menu)
import './viewport' // petits écrans : mise en page PC réduite (zoom) au lieu d'être réorganisée
import AppMenu from './components/AppMenu.vue'
import { openSessions } from './sessionsPanel'
import FlightView from './views/FlightView.vue'
import FootView from './views/FootView.vue'
import AlertOverlay from './components/AlertOverlay.vue'
import IdleScreen, { type IdleKind } from './components/IdleScreen.vue'
import MemoryBar from './components/MemoryBar.vue'
import Marquee from './components/Marquee.vue'
import ShipInfo from './components/ShipInfo.vue'
import SessionsPanel from './components/SessionsPanel.vue'
import DataUpdate from './components/DataUpdate.vue'
import MobileConnect from './components/MobileConnect.vue'
import { shipName } from './ships'

// Toujours connecté au service (sans service, simples tentatives de reconnexion). ?demo dans l'adresse ouvre la
// démo d'emblée (lien à partager, page hébergée sans service) ; elle se ferme seule si le jeu est en partie.
// ?sessions / ?mobile : ouvre ce panneau d'emblée (menu de l'icône de la zone de notification) ; le paramètre est
// ensuite retiré de l'adresse, pour qu'un rafraîchissement ne rouvre pas le panneau.
onMounted(() => {
  connect()
  const q = new URLSearchParams(location.search)
  if (q.has('demo')) showDemo('ship')
  if (q.has('sessions')) openSessions()
  if (q.has('mobile')) void mobile.value?.open()
  if (q.has('sessions') || q.has('mobile')) history.replaceState(null, '', location.pathname)
})

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
const gameCtx = computed<'vol' | 'pied' | IdleKind>(() => {
  if (demo.value) return demoView.value === 'ship' ? 'vol' : 'pied'
  if (link.value !== 'online') return 'link'
  if (!has('sc.private_mb')) return 'offline' // StarCitizen.exe absent (mesuré par le service)
  if (str('game.mode') === 'menu') return 'menu'
  if (!has(`${ACT}state.locomotion`)) return 'loading'
  const seated = str(`${ACT}state.locomotion`).endsWith('SEATED')
  return seated && has(`${VEH}class_name`) ? 'vol' : 'pied'
})
// Aux commandes, l'onglet Player permet d'aller voir l'état du personnage ; on revient à Ship d'un clic,
// et tout changement de contexte dans le jeu (quitter le siège…) annule ce choix.
const peek = ref(false)
watch(gameCtx, (c) => c !== 'vol' && (peek.value = false))
const ctx = computed(() => (!demo.value && peek.value && gameCtx.value === 'vol' ? 'pied' : gameCtx.value))
// en démo : les deux onglets ; en direct : seulement aux commandes (à pied, pas de données vaisseau à montrer)
const tabsLive = computed(() => demo.value || gameCtx.value === 'vol')
function pickTab(view: 'foot' | 'ship'): void {
  if (demo.value) showDemo(view)
  else peek.value = view === 'foot'
}
const soundLabel = computed(() => (!soundOn.value ? 'Sound off' : soundUnlocked.value ? 'Sound on' : 'Click to enable sound'))
const IDLE_LABEL: Record<string, string> = { link: 'No link', offline: 'Game not running', menu: 'Main menu', loading: 'Loading' }
const idle = computed(() => (ctx.value === 'vol' || ctx.value === 'pied' ? null : ctx.value))
const shipClass = computed(() => str(`${VEH}class_name`))
const ship = computed(() => shipName(shipClass.value))
// cadre du contexte dans l'en-tête : cliqué aux commandes, il ouvre la fiche du vaisseau (ShipInfo)
const ctxEl = ref<HTMLElement>()
// à pied (en direct), l'onglet Ship n'a pas d'écran à montrer : il ouvre la recherche de fiche vaisseau
const shipInfo = ref<InstanceType<typeof ShipInfo>>()
const shipSearch = (view: string) => view === 'ship' && !tabsLive.value
// raccourci Mobile connect dans l'en-tête (aussi dans le menu) ; seulement sur le PC (localhost)
const mobile = ref<InstanceType<typeof MobileConnect>>()

const TABS = [
  { view: 'foot', ctx: 'pied', label: 'Player' },
  { view: 'ship', ctx: 'vol', label: 'Ship' },
] as const
</script>

<template>
  <main class="page">
    <header class="top">
      <div class="brand">SC COMPANION</div>
      <div ref="ctxEl" class="ctx" :class="{ info: gameCtx === 'vol' }" aria-live="polite">
        <span class="dot" :class="{ off: link !== 'online' }" />
        <!-- contexte réel dans le jeu (pas l'onglet affiché) : le vaisseau, ou « On foot » -->
        <Marquee v-if="gameCtx === 'vol'" :text="ship" />
        <!-- petit carré fléché : la fiche du vaisseau s'ouvre d'un clic (ShipInfo) -->
        <svg v-if="gameCtx === 'vol'" class="more" viewBox="0 0 12 12" aria-hidden="true">
          <rect x="0.5" y="0.5" width="11" height="11" />
          <path d="M3.5 3.5 L8.5 8.5 M8.5 4.5 V8.5 H4.5" />
        </svg>
        <b v-else-if="gameCtx === 'pied'">On foot</b>
        <template v-else>{{ IDLE_LABEL[gameCtx] }}</template>
      </div>
      <span v-if="gameMode" class="gmode" :class="gameMode">{{ MODE_LABEL[gameMode] }}</span>
      <!-- groupe de droite : reste collé à droite, même quand l'en-tête passe sur deux lignes -->
      <div class="right">
        <div v-if="!demo" class="feed">{{ link }}<template v-if="source"> · {{ source === 'replay' ? 'capture replay' : 'live game' }}</template></div>
        <button v-if="demo" type="button" class="test call" @click="exitDemo">Exit<span class="long"> preview</span></button>
        <!-- nouvelle version du jeu sur le wiki : mise à jour des données vaisseaux (affiché seulement dans ce cas) -->
        <DataUpdate />
        <!-- le premier clic sur la page déverrouille l'audio ; ce bouton sert aussi à couper / remettre le son.
             Haut-parleur barré = son coupé ; en orange tant que le navigateur n'a pas encore autorisé le son -->
        <button
          type="button"
          class="test icon"
          :class="{ call: soundOn && !soundUnlocked }"
          :title="soundLabel"
          :aria-label="soundLabel"
          :aria-pressed="soundOn"
          @click="soundUnlocked && toggleSound()"
        >
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <path class="spk" d="M4 9h4l5-4v14l-5-4H4z" />
            <template v-if="soundOn">
              <path d="M16 9.5a3.5 3.5 0 0 1 0 5" />
              <path d="M18.5 7a7 7 0 0 1 0 10" />
            </template>
            <path v-else d="M16 9l6 6M22 9l-6 6" />
          </svg>
        </button>
        <!-- Mobile connect : QR code pour ouvrir l'appli sur le téléphone (sur le PC seulement) -->
        <button v-if="mobile?.onPc" type="button" class="test icon" title="Mobile connect" aria-label="Mobile connect" @click="mobile?.open()">
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <rect x="7" y="3" width="10" height="18" rx="1.5" />
            <path d="M11 18h2" />
          </svg>
        </button>
        <!-- Sessions enregistrées : analyse (panneau Sessions) -->
        <button type="button" class="test icon" title="Sessions" aria-label="Sessions" @click="openSessions">
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <path d="M3 6.5V19h18V8.5h-9.2L9.8 6.5Z" />
          </svg>
        </button>
        <AppMenu />
        <MobileConnect ref="mobile" />
      </div>
    </header>

    <ShipInfo ref="shipInfo" :anchor="gameCtx === 'vol' ? ctxEl : undefined" :ship="gameCtx === 'vol' ? shipClass : ''" />
    <SessionsPanel />
    <AlertOverlay />
    <MemoryBar />
    <!-- crédit SPViewer (source des données vaisseaux), onglet posé sur la bande mémoire, en bas à droite -->
    <a class="spv" href="https://www.spviewer.eu" target="_blank" rel="noopener">Ship data by <b>SPViewer</b> <span aria-hidden="true">↗</span></a>

    <!-- Onglets : en direct, ils suivent le jeu ; aux commandes, Player montre l'état du personnage ; en démo, on choisit -->
    <nav v-if="!idle" class="tabs" aria-label="Screens">
      <button
        v-for="t in TABS"
        :key="t.view"
        type="button"
        class="tab"
        :aria-current="ctx === t.ctx ? 'page' : undefined"
        :class="{ on: ctx === t.ctx, find: shipSearch(t.view) }"
        :title="shipSearch(t.view) ? 'Look up any ship' : undefined"
        :disabled="!tabsLive && !shipSearch(t.view)"
        @click="shipSearch(t.view) ? shipInfo?.searchFrom($event.currentTarget as HTMLElement) : pickTab(t.view)"
      >
        {{ t.label }}
        <svg v-if="shipSearch(t.view)" class="lens" viewBox="0 0 16 16" aria-hidden="true"><circle cx="6.5" cy="6.5" r="4.5" /><path d="M10 10l4.5 4.5" /></svg>
      </button>
      <span v-if="!tabsLive" class="tabs-hint">Follows the game</span>
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
  // en bas : la place de la bande mémoire fixe (50 px), du lien SPViewer + marge
  padding: 20px max(16px, env(safe-area-inset-right)) 100px max(16px, env(safe-area-inset-left));
}

// Une seule ligne : le contexte (nom du vaisseau) rétrécit et défile plutôt que de pousser
// le menu à la ligne. Sous 760 px, l'en-tête passe sur deux lignes (le groupe de droite reste à droite).
.top {
  display: flex;
  align-items: center;
  gap: 12px 5px;

  > * {
    flex: none;
  }

  // toujours une ligne : la page est réduite (viewport.ts) plutôt que réorganisée ;
  // seul le nom du vaisseau rétrécit et défile
}

// boutons et menu toujours collés à droite
.right {
  display: flex;
  align-items: center;
  gap: 5px;
  margin-left: auto;
}

.brand {
  @include numeric;
  color: var(--cyan);
  font-size: 15px;
  font-weight: 700;
  letter-spacing: 0.18em;
  margin-right: 15px; // le titre garde un peu plus d'air que les boutons

}

// Contexte (vaisseau / à pied) : même gabarit que PU, Menu et le bouton son (petit, angles droits)
.ctx {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  padding: 4px 10px;
  border: 1px solid var(--cyan-dim);
  background: var(--panel);
  font: 500 11px var(--font-ui);
  letter-spacing: 0.1em;
  text-transform: uppercase;
  white-space: nowrap;

  // Largeur du nom du vaisseau avant défilement (voir Marquee) : 200 px, puis 110 px sous 960 px
  // pour garder le titre sur la même ligne (le nom défile alors, même un nom court comme le F7A).
  @media (max-width: 960px) {
    --marquee-max: 110px;
  }

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

  // aux commandes : clic = fiche du vaisseau
  &.info {
    cursor: pointer;

    &:hover .more {
      color: var(--cyan);
    }
  }

  // carré fléché après le nom du vaisseau
  .more {
    width: 12px;
    height: 12px;
    color: var(--cyan-dim);
    fill: none;
    stroke: currentColor;
    stroke-width: 1.2;
    transition: color 0.15s;
  }
}

.dot {
  width: 6px;
  height: 6px;
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

// bouton picto (son) : même hauteur que les boutons texte
.test.icon {
  display: grid;
  place-items: center;
  padding: 3px 7px;

  svg {
    width: 18px;
    height: 18px;
    fill: none;
    stroke: currentColor;
    stroke-width: 1.6;
    stroke-linecap: round;
    stroke-linejoin: round;
  }

  .spk {
    fill: currentColor;
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
  @include bevel-edges(8px);
  position: relative;
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

  // survol en jaune (aussi sur l'onglet actif)
  &:hover:not(:disabled) {
    border-color: var(--amber);
    color: var(--amber);
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

.tab:disabled:not(.on) {
  opacity: 0.55;
}

// onglet Ship à pied : ouvre la recherche de fiche vaisseau (loupe)
.lens {
  width: 11px;
  height: 11px;
  margin-left: 6px;
  vertical-align: -1px;
  fill: none;
  stroke: currentColor;
  stroke-width: 1.8;
  stroke-linecap: round;
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

// Lien SPViewer : fixé au-dessus de la bande mémoire (50 px), sous elle quand son détail est déplié (z-index 50)
.spv {
  position: fixed;
  right: env(safe-area-inset-right, 0px); // collé au bord de l'écran : se détache du contenu
  // collé à la bande mémoire (50 px + sa bordure du haut) : un onglet posé dessus, sans bordure basse
  bottom: calc(51px + env(safe-area-inset-bottom, 0px));
  z-index: 40;
  padding: 4px 9px 3px 12px;
  border: 1px solid var(--line);
  border-bottom: 0;
  border-right: 0;
  clip-path: polygon(8px 0, 100% 0, 100% 100%, 0 100%, 0 8px); // coin haut gauche coupé, comme les onglets
  @include bevel-edges(8px, $br: false);
  background: var(--panel);
  color: var(--muted);
  font: 500 10px var(--font-ui);
  letter-spacing: 0.06em;
  text-decoration: none;

  b {
    color: var(--text);
    font-weight: 600;
    letter-spacing: 0.1em;
    text-transform: uppercase;
  }

  // survol en jaune, comme les onglets
  &:hover {
    border-color: var(--amber);
    color: var(--amber);

    b {
      color: var(--amber);
    }
  }

  &:focus-visible {
    outline: 2px solid var(--amber);
    outline-offset: 1px;
  }
}

// ---- Téléphone : en-tête sur une ligne, marges et onglets réduits ----
@include phone {
  .page {
    gap: 8px;
    // en bas : bande mémoire (50 px) + crédit SPViewer posé dessus
    padding: 8px max(8px, env(safe-area-inset-right)) 84px max(8px, env(safe-area-inset-left));
  }

  .top {
    flex-wrap: nowrap;
  }

  // le contexte rétrécit (le nom défile) au lieu de passer sous PU
  .ctx {
    overflow: hidden;
    padding: 4px 8px;
  }

  .right {
    gap: 4px;
  }

  .test {
    padding: 5px 7px;
  }

  .test.icon {
    padding: 3px 5px;
  }

  // « Exit preview » → « Exit »
  .long {
    display: none;
  }

  // le titre de l'appli cède sa place : le contexte (vaisseau / à pied) est plus utile
  .brand {
    display: none;
  }

  .tabs {
    margin-bottom: 0;
  }

  .tab {
    flex: 1;
    min-width: 0;
    padding: 4px 10px;
    font-size: 11px;
  }

  .tabs-hint {
    display: none;
  }
}
</style>
