<script setup lang="ts">
// Menu de l'en-tête : Ace pilot et affichage en tête, puis alertes (activables une par une) et tests, dépliables.
// Les réglages sont mémorisés dans le navigateur (settings.ts). D'autres sections viendront (seuils RAM…).
// Se ferme avec Échap ou un clic à l'extérieur ; un clic dans le menu (case à cocher) le laisse ouvert.
import { onBeforeUnmount, ref, watch } from 'vue'
import { TESTS, type TestKind, shownAlert, triggerTest } from '@/alerts'
import { flash } from '@/hit'
import { ALERT_GROUPS, COMPONENT_ALERTS, settings } from '@/settings'
import { awake, canFullscreen, fullscreen, toggleFullscreen } from '@/wakelock'
import MobileConnect from './MobileConnect.vue'

// méthode en cours (diagnostic : la vidéo de repli ne marche pas sur tous les téléphones)
const AWAKE_NOTE = { system: 'Active · system lock', video: 'Active · video fallback', pending: 'Tap anywhere on the page to activate' }

const open = ref(false)
// fenêtre Mobile connect : hors du panneau (qui se ferme), ouverte par son entrée du menu
const mobile = ref<InstanceType<typeof MobileConnect>>()
function openMobile(): void {
  open.value = false
  void mobile.value?.open()
}
const testsOpen = ref(false)
const alertsOpen = ref(false)
const root = ref<HTMLElement | null>(null)

// Écouteurs posés seulement quand le menu est ouvert : rien ne tourne le reste du temps
function onDown(e: PointerEvent): void {
  if (!root.value?.contains(e.target as Node)) open.value = false
}
function onKey(e: KeyboardEvent): void {
  if (e.key === 'Escape') open.value = false
}
watch(open, (o) => {
  const fn = o ? window.addEventListener : window.removeEventListener
  fn('pointerdown', onDown as EventListener)
  fn('keydown', onKey as EventListener)
})
onBeforeUnmount(() => (open.value = false))

const KINDS = Object.keys(TESTS) as TestKind[]
function test(kind: TestKind | 'hit'): void {
  if (kind === 'hit') flash()
  else triggerTest(kind)
}

const allOn = () => ALERT_GROUPS.every((g) => settings.alerts[g.key])
function toggleAll(): void {
  const v = !allOn()
  for (const g of ALERT_GROUPS) settings.alerts[g.key] = v
  setComponents(v)
}

// « Component damaged » : la case principale coche / décoche tous les composants ; la flèche déplie la liste.
// À moitié cochée quand seuls certains composants sont actifs.
const compOpen = ref(false)
const compCount = () => COMPONENT_ALERTS.filter((c) => settings.components[c.key]).length
const compPartial = () => settings.alerts.components && compCount() > 0 && compCount() < COMPONENT_ALERTS.length
function setComponents(v: boolean): void {
  settings.alerts.components = v
  for (const c of COMPONENT_ALERTS) settings.components[c.key] = v
}
// un composant coché rallume l'alerte ; le dernier décoché l'éteint
function onComponent(): void {
  settings.alerts.components = compCount() > 0
}
</script>

<template>
  <div ref="root" class="menu">
    <button type="button" class="test" :aria-expanded="open" aria-haspopup="true" @click="open = !open">
      Menu <span class="caret" :class="{ up: open }">▾</span>
    </button>

    <div v-if="open" class="panel">
      <!-- Réglages directs : profil des alertes de vol, puis affichage -->
      <section>
        <!-- profil des alertes de vol : bien plus tolérant à la prise de risque (crash.ts) -->
        <label class="check">
          <input v-model="settings.acePilot" type="checkbox" />
          <span class="box" aria-hidden="true" />
          Ace pilot
        </label>
        <p class="note">{{ settings.acePilot ? 'Late flight warnings, risk-tolerant' : 'Early flight warnings' }}</p>
        <label class="check">
          <input v-model="settings.keepAwake" type="checkbox" />
          <span class="box" aria-hidden="true" />
          Keep screen on
        </label>
        <p v-if="awake !== 'off'" class="note" :class="awake">{{ AWAKE_NOTE[awake] }}</p>
        <button v-if="canFullscreen" type="button" class="row" @click="toggleFullscreen">
          <span>{{ fullscreen ? 'Exit full screen' : 'Full screen' }}</span>
          <span aria-hidden="true">⛶</span>
        </button>
        <button v-if="mobile?.onPc" type="button" class="row" @click="openMobile">
          <span>Mobile connect</span>
        </button>
      </section>

      <!-- Alertes : sous-liste dépliable, une case par groupe -->
      <section>
        <button type="button" class="row" :aria-expanded="alertsOpen" @click="alertsOpen = !alertsOpen">
          <span>Alerts</span>
          <span class="caret" :class="{ side: !alertsOpen }">▾</span>
        </button>
        <div v-if="alertsOpen" class="subchecks">
          <div class="all">
            <button type="button" class="link" @click="toggleAll">{{ allOn() ? 'None' : 'All' }}</button>
          </div>
          <!-- Une ligne par groupe : case = l'alerte (affichage), haut-parleur à droite = son son, indépendant -->
          <template v-for="g in ALERT_GROUPS" :key="g.key">
            <div class="with-sub">
              <!-- Component damaged : case principale (tous les composants) + flèche qui déplie un réglage par composant -->
              <template v-if="g.key === 'components'">
                <label class="check">
                  <input
                    type="checkbox"
                    :checked="settings.alerts.components"
                    :indeterminate="compPartial()"
                    @change="setComponents(($event.target as HTMLInputElement).checked)"
                  />
                  <span class="box" :class="{ partial: compPartial() }" aria-hidden="true" />
                  {{ g.label }}
                </label>
                <button type="button" class="arrow" :aria-expanded="compOpen" aria-label="Show components" @click="compOpen = !compOpen">
                  <span class="caret" :class="{ side: !compOpen }">▾</span>
                </button>
              </template>
              <label v-else class="check">
                <input v-model="settings.alerts[g.key]" type="checkbox" />
                <span class="box" aria-hidden="true" />
                {{ g.label }}
              </label>
              <!-- le flash de tir n'a pas de son : place vide pour garder les haut-parleurs alignés -->
              <span v-if="'silent' in g" class="snd" aria-hidden="true" />
              <button
                v-else
                type="button"
                class="snd"
                :class="{ muted: !settings.sound[g.key] }"
                :disabled="!settings.alerts[g.key]"
                :aria-pressed="settings.sound[g.key]"
                :title="settings.sound[g.key] ? 'Sound on' : 'Sound off'"
                :aria-label="`${g.label} sound`"
                @click="settings.sound[g.key] = !settings.sound[g.key]"
              >
                <svg viewBox="0 0 24 24" aria-hidden="true">
                  <path class="spk" d="M4 9h4l5-4v14l-5-4H4z" />
                  <path v-if="settings.sound[g.key]" d="M16 9.5a3.5 3.5 0 0 1 0 5M18.5 7a7 7 0 0 1 0 10" />
                  <path v-else d="M16 9l6 6M22 9l-6 6" />
                </svg>
              </button>
            </div>
            <div v-if="g.key === 'components' && compOpen" class="subchecks">
              <label v-for="c in COMPONENT_ALERTS" :key="c.key" class="check">
                <input v-model="settings.components[c.key]" type="checkbox" @change="onComponent" />
                <span class="box" aria-hidden="true" />
                {{ c.label }}
              </label>
            </div>
          </template>
        </div>
      </section>

      <!-- Tests : sous-liste dépliable -->
      <section>
        <button type="button" class="row" :aria-expanded="testsOpen" @click="testsOpen = !testsOpen">
          <span>Test alerts</span>
          <span class="caret" :class="{ side: !testsOpen }">▾</span>
        </button>
        <div v-if="testsOpen" class="sub">
          <button v-for="k in KINDS" :key="k" type="button" :class="TESTS[k].item.level" :disabled="!!shownAlert" @click="test(k)">
            <span class="sw" />{{ TESTS[k].label }}
          </button>
          <button type="button" class="hit" @click="test('hit')"><span class="sw" />Hit flash</button>
        </div>
      </section>
    </div>
    <MobileConnect ref="mobile" />
  </div>
</template>

<style scoped lang="scss">
.menu {
  position: relative;
}

// même apparence que les autres boutons de l'en-tête
.test {
  padding: 5px 10px;
  border: 1px solid var(--line);
  background: var(--panel);
  color: var(--muted);
  font: 500 11px var(--font-ui);
  letter-spacing: 0.08em;
  text-transform: uppercase;
  cursor: pointer;

  &:hover,
  &[aria-expanded='true'] {
    border-color: var(--cyan-dim);
    color: var(--cyan);
  }
}

button:focus-visible,
.check:has(input:focus-visible) {
  outline: 2px solid var(--amber);
  outline-offset: 1px;
}

.caret {
  display: inline-block;
  margin-left: 4px;
  transition: transform 0.15s;

  &.up {
    transform: rotate(180deg);
  }

  &.side {
    transform: rotate(-90deg);
  }
}

.panel {
  position: absolute;
  z-index: 20;
  top: calc(100% + 4px);
  right: 0;
  display: grid;
  gap: 4px;
  width: 250px;
  // sous l'en-tête et au-dessus de la bande mémoire (50 px) + le crédit SPViewer
  max-height: calc(100vh - 160px);
  overflow-y: auto;
  padding: 8px;
  border: 1px solid var(--cyan-dim);
  @include bevel-edges-bg(8px, var(--cyan-dim), var(--panel)); // le menu défile : diagonales en dégradés
  @include bevel(8px);

  section + section {
    padding-top: 6px;
    border-top: 1px solid var(--line);
  }
}

// ligne d'explication sous une case (Ace pilot, Keep screen on)
.note {
  margin: 0;
  padding: 0 6px 4px 30px;
  color: var(--muted);

  &.pending {
    color: var(--amber);
  }
  font: 500 10px var(--font-ui);
  letter-spacing: 0.04em;
}

.link {
  padding: 0;
  border: 0;
  background: none;
  color: var(--cyan-dim);
  font: 500 10px var(--font-ui);
  letter-spacing: 0.1em;
  text-transform: uppercase;
  cursor: pointer;

  &:hover {
    color: var(--cyan);
  }
}

// Case à cocher dessinée (la vraie reste dans la page, invisible, pour le clavier et les lecteurs d'écran)
.check {
  position: relative;
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 6px;
  color: var(--text);
  font: 500 12px var(--font-ui);
  letter-spacing: 0.04em;
  cursor: pointer;

  &:hover {
    background: rgb(99 228 221 / 6%);
  }

  input {
    position: absolute;
    opacity: 0;
    pointer-events: none;
  }

  .box {
    flex: none;
    width: 12px;
    height: 12px;
    border: 1px solid var(--cyan-dim);
  }

  input:checked + .box {
    border-color: var(--cyan);
    background: var(--cyan);
    box-shadow: inset 0 0 0 2px var(--panel);
  }

  // à moitié cochée : un trait au milieu
  .box.partial {
    border-color: var(--cyan);
    background: linear-gradient(var(--cyan), var(--cyan)) center / 6px 2px no-repeat;
  }

  &:has(input:not(:checked)) {
    color: var(--muted);
  }
}

.with-sub {
  display: flex;
  align-items: center;

  .check {
    flex: 1;
  }
}

// Haut-parleur : son de l'alerte (barré = muet). Grisé quand l'alerte elle-même est désactivée.
.snd {
  flex: none;
  display: grid;
  place-items: center;
  width: 28px;
  height: 26px;
  padding: 0;
  border: 0;
  background: none;
  color: var(--cyan);
  cursor: pointer;

  &:hover:not(:disabled) {
    background: rgb(99 228 221 / 6%);
  }

  &.muted {
    color: var(--muted);
  }

  &:disabled {
    opacity: 0.35;
    cursor: default;
  }

  svg {
    width: 15px;
    height: 15px;
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

.arrow {
  padding: 6px 8px;
  border: 0;
  background: none;
  color: var(--muted);
  cursor: pointer;

  &:hover {
    color: var(--cyan);
  }
}

.subchecks {
  padding-left: 12px;

  // « All / None » en tête de la liste des alertes
  .all {
    display: flex;
    justify-content: flex-end;
    padding: 2px 6px 4px;
  }
}

.row,
.sub button {
  display: flex;
  align-items: center;
  width: 100%;
  border: 0;
  background: none;
  text-align: left;
  cursor: pointer;
}

.row {
  justify-content: space-between;
  padding: 6px;
  color: var(--text);
  font: 500 12px var(--font-ui);
  letter-spacing: 0.04em;

  &:hover {
    background: rgb(99 228 221 / 6%);
  }
}

.sub {
  display: grid;
  padding-left: 12px;

  button {
    gap: 8px;
    padding: 6px;
    color: var(--text);
    font: 500 11px var(--font-ui);
    letter-spacing: 0.06em;
    text-transform: uppercase;

    &:hover:not(:disabled) {
      background: rgb(99 228 221 / 8%);
      color: var(--cyan);
    }

    &:disabled {
      opacity: 0.45;
      cursor: default;
    }
  }
}

// pastille de couleur : niveau de l'alerte testée
.sw {
  flex: none;
  width: 8px;
  height: 8px;
  background: var(--cyan);
}

.warning .sw {
  background: var(--amber);
}

.info .sw {
  background: var(--green);
}

.critical .sw,
.hit .sw {
  background: var(--red);
}
</style>
